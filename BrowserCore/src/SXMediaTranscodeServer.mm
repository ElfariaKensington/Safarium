// SXMediaTranscodeServer.mm
// Same-origin CefResourceHandler for on-the-fly MP4/H.264/AAC -> WebM (VP8+Opus)
// transcoding with disk caching (HTTP 206 byte ranges) and AVFoundation duration probe.

#import "SXMediaTranscodeServer.h"

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <condition_variable>
#include <deque>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

std::string FindFFmpegPath() {
  const char* candidates[] = {
      "/opt/homebrew/bin/ffmpeg",
      "/usr/local/bin/ffmpeg",
      "/usr/bin/ffmpeg",
  };
  for (const char* p : candidates) {
    if (access(p, X_OK) == 0) return p;
  }
  return "ffmpeg";
}

std::string GetCacheDir() {
  static std::string dir;
  static std::once_flag once;
  std::call_once(once, []() {
    @autoreleasepool {
      NSString* nsDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"sx_media_cache"];
      [[NSFileManager defaultManager] createDirectoryAtPath:nsDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
      dir = nsDir.UTF8String ? std::string(nsDir.UTF8String) : "/tmp/sx_media_cache";
    }
  });
  return dir;
}

std::string SHA256Hex(const std::string& input) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(input.data(), static_cast<CC_LONG>(input.size()), digest);
  static const char kHex[] = "0123456789abcdef";
  std::string out;
  out.reserve(CC_SHA256_DIGEST_LENGTH * 2);
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
    out.push_back(kHex[(digest[i] >> 4) & 0xF]);
    out.push_back(kHex[digest[i] & 0xF]);
  }
  return out;
}

std::string SanitizeHeaderValue(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    if (c != '\r' && c != '\n' && c != '\0') out.push_back(c);
  }
  return out;
}

struct ParsedSXURL {
  bool is_transcode = false;
  bool is_meta = false;
  double seek_sec = 0.0;
  std::string clean_url;
};

ParsedSXURL ParseSXMediaURL(const std::string& raw_url) {
  ParsedSXURL res;
  size_t qpos = raw_url.find('?');
  if (qpos == std::string::npos) return res;

  std::string base = raw_url.substr(0, qpos);
  std::string query = raw_url.substr(qpos + 1);
  std::string hash;
  size_t hpos = query.find('#');
  if (hpos != std::string::npos) {
    hash = query.substr(hpos);
    query = query.substr(0, hpos);
  }

  std::vector<std::string> kept;
  size_t pos = 0;
  while (pos < query.size()) {
    size_t amp = query.find('&', pos);
    if (amp == std::string::npos) amp = query.size();
    std::string part = query.substr(pos, amp - pos);
    if (part == "__sx_tc=1") {
      res.is_transcode = true;
    } else if (part == "__sx_meta=1") {
      res.is_meta = true;
    } else if (part.rfind("__sx_t=", 0) == 0) {
      res.seek_sec = std::max(0.0, std::atof(part.c_str() + 7));
    } else if (!part.empty()) {
      kept.push_back(part);
    }
    pos = amp + 1;
  }

  if (!res.is_transcode && !res.is_meta) return res;

  res.clean_url = base;
  if (!kept.empty()) {
    res.clean_url.push_back('?');
    for (size_t i = 0; i < kept.size(); ++i) {
      if (i > 0) res.clean_url.push_back('&');
      res.clean_url += kept[i];
    }
  }
  res.clean_url += hash;
  return res;
}

double ProbeDurationSeconds(const std::string& url, const std::string& referer) {
  @autoreleasepool {
    NSString* nsURLStr = [NSString stringWithUTF8String:url.c_str()];
    if (!nsURLStr) return 0.0;
    NSURL* nsURL = [NSURL URLWithString:nsURLStr];
    if (!nsURL) return 0.0;
    NSMutableDictionary* options = [NSMutableDictionary dictionary];
    if (!referer.empty()) {
      NSString* refStr = [NSString stringWithUTF8String:referer.c_str()];
      if (refStr) {
        options[@"AVURLAssetHTTPHeaderFieldsKey"] = @{@"Referer" : refStr};
      }
    }
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:nsURL options:options];
    if (!asset) return 0.0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block double result = 0.0;
    [asset loadValuesAsynchronouslyForKeys:@[@"duration"]
                         completionHandler:^{
                           NSError* err = nil;
                           if ([asset statusOfValueForKey:@"duration" error:&err] ==
                               AVKeyValueStatusLoaded) {
                             CMTime dur = asset.duration;
                             if (CMTIME_IS_NUMERIC(dur)) {
                               double sec = CMTimeGetSeconds(dur);
                               if (std::isfinite(sec) && sec > 0.0) {
                                 result = sec;
                               }
                             }
                           }
                           dispatch_semaphore_signal(sem);
                         }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
    return result;
  }
}

// -----------------------------------------------------------------------------
// 1. Metadata JSON handler (`?__sx_meta=1`)
// -----------------------------------------------------------------------------
class SXMediaMetaResourceHandler : public CefResourceHandler {
 public:
  SXMediaMetaResourceHandler(std::string clean_url, std::string referer)
      : clean_url_(std::move(clean_url)), referer_(std::move(referer)) {}

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    handle_request = false;
    CefRefPtr<SXMediaMetaResourceHandler> self(this);
    std::thread([self, callback]() {
      double dur = ProbeDurationSeconds(self->clean_url_, self->referer_);
      char json[128];
      snprintf(json, sizeof(json), "{\"duration\":%.3f}", dur);
      self->body_ = json;
      callback->Continue();
    }).detach();
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override {
    response->SetStatus(200);
    response->SetStatusText("OK");
    response->SetMimeType("application/json");
    CefResponse::HeaderMap headers;
    headers.emplace("Cache-Control", "no-store");
    headers.emplace("Access-Control-Allow-Origin", "*");
    response->SetHeaderMap(headers);
    response_length = static_cast<int64_t>(body_.size());
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    if (offset_ >= body_.size()) {
      bytes_read = 0;
      return false;
    }
    size_t avail = body_.size() - offset_;
    size_t to_copy = std::min<size_t>(avail, static_cast<size_t>(bytes_to_read));
    memcpy(data_out, body_.data() + offset_, to_copy);
    offset_ += to_copy;
    bytes_read = static_cast<int>(to_copy);
    return true;
  }

  void Cancel() override {}

 private:
  std::string clean_url_;
  std::string referer_;
  std::string body_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(SXMediaMetaResourceHandler);
};

// -----------------------------------------------------------------------------
// 2. Cached WebM File Handler (HTTP 206 Partial Content byte-range support)
// -----------------------------------------------------------------------------
class SXCachedMediaResourceHandler : public CefResourceHandler {
 public:
  explicit SXCachedMediaResourceHandler(std::string path)
      : path_(std::move(path)) {}

  ~SXCachedMediaResourceHandler() override {
    if (fd_ >= 0) close(fd_);
  }

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    handle_request = true;
    fd_ = open(path_.c_str(), O_RDONLY);
    if (fd_ < 0) return false;
    struct stat st;
    if (fstat(fd_, &st) != 0 || st.st_size <= 0) {
      close(fd_);
      fd_ = -1;
      return false;
    }
    total_size_ = static_cast<int64_t>(st.st_size);
    start_ = 0;
    end_ = total_size_ - 1;

    CefRequest::HeaderMap headers;
    request->GetHeaderMap(headers);
    std::string range_hdr;
    for (const auto& kv : headers) {
      std::string k = kv.first.ToString();
      if (strcasecmp(k.c_str(), "Range") == 0) {
        range_hdr = kv.second.ToString();
        break;
      }
    }
    if (!range_hdr.empty() && range_hdr.rfind("bytes=", 0) == 0) {
      std::string spec = range_hdr.substr(6);
      size_t dash = spec.find('-');
      if (dash != std::string::npos) {
        std::string s1 = spec.substr(0, dash);
        std::string s2 = spec.substr(dash + 1);
        if (!s1.empty()) {
          start_ = std::max<int64_t>(0, std::atoll(s1.c_str()));
          if (!s2.empty()) {
            end_ = std::min<int64_t>(total_size_ - 1, std::atoll(s2.c_str()));
          }
          partial_ = true;
        } else if (!s2.empty()) {
          int64_t suffix = std::atoll(s2.c_str());
          start_ = std::max<int64_t>(0, total_size_ - suffix);
          partial_ = true;
        }
      }
    }
    if (start_ >= total_size_ || start_ > end_) {
      start_ = 0;
      end_ = total_size_ - 1;
      partial_ = false;
    }
    remaining_ = end_ - start_ + 1;
    lseek(fd_, start_, SEEK_SET);
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override {
    CefResponse::HeaderMap headers;
    headers.emplace("Accept-Ranges", "bytes");
    headers.emplace("Access-Control-Allow-Origin", "*");
    if (partial_) {
      response->SetStatus(206);
      response->SetStatusText("Partial Content");
      char cr[128];
      snprintf(cr, sizeof(cr), "bytes %lld-%lld/%lld",
               static_cast<long long>(start_),
               static_cast<long long>(end_),
               static_cast<long long>(total_size_));
      headers.emplace("Content-Range", cr);
    } else {
      response->SetStatus(200);
      response->SetStatusText("OK");
    }
    response->SetMimeType("video/webm");
    response->SetHeaderMap(headers);
    response_length = remaining_;
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    if (fd_ < 0 || remaining_ <= 0) {
      bytes_read = 0;
      return false;
    }
    size_t to_read = static_cast<size_t>(std::min<int64_t>(remaining_, bytes_to_read));
    ssize_t n = read(fd_, data_out, to_read);
    if (n <= 0) {
      bytes_read = 0;
      return false;
    }
    remaining_ -= n;
    bytes_read = static_cast<int>(n);
    return true;
  }

  void Cancel() override {
    if (fd_ >= 0) {
      close(fd_);
      fd_ = -1;
    }
  }

 private:
  std::string path_;
  int fd_ = -1;
  int64_t total_size_ = 0;
  int64_t start_ = 0;
  int64_t end_ = 0;
  int64_t remaining_ = 0;
  bool partial_ = false;
  IMPLEMENT_REFCOUNTING(SXCachedMediaResourceHandler);
};

// Injects an EBML Duration element (float64 ms) into the WebM Segment Info header
// so Chromium reports the real duration immediately on uncached piped streams.
bool InjectWebMDuration(std::vector<uint8_t>& buf, double duration_sec) {
  if (!(duration_sec > 0.0) || !std::isfinite(duration_sec) || buf.size() < 64) return false;
  const size_t scan_limit = std::min<size_t>(buf.size(), 4096);
  for (size_t i = 0; i + 16 < scan_limit; ++i) {
    if (buf[i] != 0x15 || buf[i + 1] != 0x49 || buf[i + 2] != 0xA9 || buf[i + 3] != 0x66) continue;
    uint8_t b0 = buf[i + 4];
    int vlen = 1;
    while (vlen <= 8 && !(b0 & (0x80 >> (vlen - 1)))) ++vlen;
    if (vlen > 8 || i + 4 + static_cast<size_t>(vlen) >= buf.size()) continue;
    uint64_t val = b0 & ((0x80 >> (vlen - 1)) - 1);
    for (int k = 1; k < vlen; ++k) val = (val << 8) | buf[i + 4 + k];
    size_t info_start = i + 4 + static_cast<size_t>(vlen);
    size_t info_end = info_start + static_cast<size_t>(val);
    if (info_end > buf.size()) continue;
    // Verify this is the actual Info element (contains TimestampScale 2A D7 B1), not a SeekHead entry.
    bool has_ts_scale = false;
    bool has_duration = false;
    for (size_t j = info_start; j + 3 <= info_end; ++j) {
      if (buf[j] == 0x2A && buf[j + 1] == 0xD7 && buf[j + 2] == 0xB1) has_ts_scale = true;
      if (buf[j] == 0x44 && buf[j + 1] == 0x89) has_duration = true;
    }
    if (!has_ts_scale || has_duration) continue;
    uint64_t new_val = val + 11;
    uint64_t max_vint = (vlen == 8) ? ((1ULL << 56) - 2) : ((1ULL << (7 * vlen)) - 2);
    if (new_val > max_vint) return false;
    for (int k = vlen - 1; k >= 0; --k) {
      buf[i + 4 + k] = static_cast<uint8_t>(new_val & 0xFF);
      new_val >>= 8;
    }
    buf[i + 4] |= static_cast<uint8_t>(0x80 >> (vlen - 1));
    double ms = duration_sec * 1000.0;
    uint64_t bits = 0;
    memcpy(&bits, &ms, sizeof(bits));
    uint8_t dur_elem[11];
    dur_elem[0] = 0x44;
    dur_elem[1] = 0x89;
    dur_elem[2] = 0x88;
    for (int k = 0; k < 8; ++k) dur_elem[3 + k] = static_cast<uint8_t>((bits >> (56 - 8 * k)) & 0xFF);
    buf.insert(buf.begin() + static_cast<ptrdiff_t>(info_end), dur_elem, dur_elem + 11);
    return true;
  }
  return false;
}

// -----------------------------------------------------------------------------
// 3. Streaming FFmpeg Transcode Handler (MP4/H.264/AAC -> WebM VP8+Opus)
// -----------------------------------------------------------------------------
class SXStreamingTranscodeResourceHandler : public CefResourceHandler {
 public:
  SXStreamingTranscodeResourceHandler(std::string clean_url,
                                      std::string referer,
                                      std::string cache_path,
                                      double seek_sec)
      : clean_url_(std::move(clean_url)),
        referer_(std::move(referer)),
        cache_path_(std::move(cache_path)),
        seek_sec_(seek_sec) {}

  ~SXStreamingTranscodeResourceHandler() override {
    Cancel();
  }

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    handle_request = true;

    int pipefd[2];
    if (pipe(pipefd) != 0) return false;

    std::vector<std::string> argv_str;
    argv_str.push_back(FindFFmpegPath());
    argv_str.push_back("-hide_banner");
    argv_str.push_back("-loglevel");
    argv_str.push_back("error");
    argv_str.push_back("-nostdin");
    if (!referer_.empty()) {
      argv_str.push_back("-headers");
      argv_str.push_back("Referer: " + SanitizeHeaderValue(referer_) + "\r\n");
    }
    if (seek_sec_ > 0.05) {
      char ssbuf[32];
      snprintf(ssbuf, sizeof(ssbuf), "%.3f", seek_sec_);
      argv_str.push_back("-ss");
      argv_str.push_back(ssbuf);
    }
    argv_str.push_back("-i");
    argv_str.push_back(clean_url_);
    argv_str.push_back("-map");
    argv_str.push_back("0:v:0");
    argv_str.push_back("-map");
    argv_str.push_back("0:a:0?");
    // Clamp >1080p down to 1080p so 4K H.264 transcodes in real-time (<0.5s startup).
    argv_str.push_back("-vf");
    argv_str.push_back("scale='min(1920,iw)':-2");
    argv_str.push_back("-c:v");
    argv_str.push_back("libvpx");
    argv_str.push_back("-deadline");
    argv_str.push_back("realtime");
    argv_str.push_back("-cpu-used");
    argv_str.push_back("8");
    argv_str.push_back("-crf");
    argv_str.push_back("24");
    argv_str.push_back("-b:v");
    argv_str.push_back("2500k");
    argv_str.push_back("-threads");
    argv_str.push_back("6");
    argv_str.push_back("-g");
    argv_str.push_back("60");
    argv_str.push_back("-c:a");
    argv_str.push_back("libopus");
    argv_str.push_back("-b:a");
    argv_str.push_back("128k");
    argv_str.push_back("-f");
    argv_str.push_back("webm");
    argv_str.push_back("-cluster_time_limit");
    argv_str.push_back("400");
    argv_str.push_back("-cluster_size_limit");
    argv_str.push_back("524288");
    argv_str.push_back("pipe:1");

    pid_t pid = fork();
    if (pid < 0) {
      close(pipefd[0]);
      close(pipefd[1]);
      return false;
    }

    if (pid == 0) {
      dup2(pipefd[1], STDOUT_FILENO);
      int devnull = open("/dev/null", O_RDWR);
      if (devnull >= 0) {
        dup2(devnull, STDIN_FILENO);
        dup2(devnull, STDERR_FILENO);
        close(devnull);
      }
      close(pipefd[0]);
      close(pipefd[1]);
      std::vector<char*> cargv;
      cargv.reserve(argv_str.size() + 1);
      for (auto& s : argv_str) cargv.push_back(const_cast<char*>(s.c_str()));
      cargv.push_back(nullptr);
      execvp(cargv[0], cargv.data());
      _exit(127);
    }

    close(pipefd[1]);
    {
      std::lock_guard<std::mutex> lock(mu_);
      child_pid_ = pid;
    }

    CefRefPtr<SXStreamingTranscodeResourceHandler> self(this);
    int read_fd = pipefd[0];
    auto dur_future = std::make_shared<std::future<double>>(
        std::async(std::launch::async, ProbeDurationSeconds, clean_url_, referer_));
    std::thread([self, read_fd, pid, dur_future]() {
      static std::atomic<uint64_t> tmp_seq{1};
      std::string tmp_path;
      int tmp_fd = -1;
      if (self->seek_sec_ <= 0.05 && !self->cache_path_.empty()) {
        tmp_path = self->cache_path_ + "." + std::to_string(tmp_seq.fetch_add(1)) + ".tmp";
        tmp_fd = open(tmp_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
      }

      uint8_t chunk[32768];
      size_t total_bytes = 0;
      bool clean_eof = false;
      bool header_patched = false;

      while (true) {
        ssize_t n = read(read_fd, chunk, sizeof(chunk));
        if (n < 0) {
          if (errno == EINTR) continue;
          break;
        }
        if (n == 0) {
          clean_eof = true;
          break;
        }
        const uint8_t* emit_ptr = chunk;
        size_t emit_len = static_cast<size_t>(n);
        std::vector<uint8_t> patched;
        if (!header_patched) {
          header_patched = true;
          if (dur_future && dur_future->wait_for(std::chrono::milliseconds(300)) == std::future_status::ready) {
            double dur = dur_future->get();
            if (self->seek_sec_ > 0.05) dur = std::max(0.0, dur - self->seek_sec_);
            if (dur > 0.0) {
              patched.assign(chunk, chunk + n);
              if (InjectWebMDuration(patched, dur)) {
                emit_ptr = patched.data();
                emit_len = patched.size();
              }
            }
          }
        }
        if (tmp_fd >= 0) {
          if (write(tmp_fd, emit_ptr, emit_len) < 0) {
            close(tmp_fd);
            tmp_fd = -1;
            unlink(tmp_path.c_str());
          }
        }
        total_bytes += emit_len;

        CefRefPtr<CefResourceReadCallback> cb;
        int cb_bytes = 0;
        {
          std::unique_lock<std::mutex> lock(self->mu_);
          // Back-pressure: stop draining ffmpeg's pipe while the player is behind, so a slow/paused video cannot
          // grow this buffer without bound (ffmpeg blocks on the full pipe instead).
          self->space_cv_.wait(lock, [&] { return self->cancelled_ || self->buffer_.size() < kMaxBufferedBytes; });
          if (self->cancelled_) break;
          self->buffer_.insert(self->buffer_.end(), emit_ptr, emit_ptr + emit_len);
          if (self->pending_cb_ && self->pending_out_ && self->pending_cap_ > 0) {
            size_t take = std::min<size_t>(self->buffer_.size(), static_cast<size_t>(self->pending_cap_));
            for (size_t i = 0; i < take; ++i) {
              static_cast<uint8_t*>(self->pending_out_)[i] = self->buffer_.front();
              self->buffer_.pop_front();
            }
            cb = self->pending_cb_;
            cb_bytes = static_cast<int>(take);
            self->pending_cb_ = nullptr;
            self->pending_out_ = nullptr;
            self->pending_cap_ = 0;
          }
        }
        if (cb) cb->Continue(cb_bytes);
      }

      close(read_fd);

      int status = 0;
      waitpid(pid, &status, 0);

      bool was_cancelled = false;
      CefRefPtr<CefResourceReadCallback> eof_cb;
      {
        std::lock_guard<std::mutex> lock(self->mu_);
        self->child_pid_ = -1;
        self->eof_ = true;
        was_cancelled = self->cancelled_;
        if (self->pending_cb_) {
          eof_cb = self->pending_cb_;
          self->pending_cb_ = nullptr;
          self->pending_out_ = nullptr;
          self->pending_cap_ = 0;
        }
      }
      if (eof_cb) eof_cb->Continue(0);

      if (tmp_fd >= 0) {
        close(tmp_fd);
        if (!was_cancelled && clean_eof && WIFEXITED(status) && WEXITSTATUS(status) == 0 && total_bytes > 1024) {
          rename(tmp_path.c_str(), self->cache_path_.c_str());
        } else {
          unlink(tmp_path.c_str());
        }
      }
    }).detach();

    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override {
    response->SetStatus(200);
    response->SetStatusText("OK");
    response->SetMimeType("video/webm");
    CefResponse::HeaderMap headers;
    headers.emplace("Cache-Control", "no-store");
    headers.emplace("Access-Control-Allow-Origin", "*");
    response->SetHeaderMap(headers);
    response_length = -1;  // Chunked streaming unknown length
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    std::lock_guard<std::mutex> lock(mu_);
    if (!buffer_.empty()) {
      size_t take = std::min<size_t>(buffer_.size(), static_cast<size_t>(bytes_to_read));
      uint8_t* dst = static_cast<uint8_t*>(data_out);
      for (size_t i = 0; i < take; ++i) {
        dst[i] = buffer_.front();
        buffer_.pop_front();
      }
      bytes_read = static_cast<int>(take);
      space_cv_.notify_one();
      return true;
    }
    if (eof_ || cancelled_) {
      bytes_read = 0;
      return false;
    }
    bytes_read = 0;
    pending_out_ = data_out;
    pending_cap_ = bytes_to_read;
    pending_cb_ = callback;
    return true;
  }

  void Cancel() override {
    pid_t pid_to_kill = -1;
    {
      std::lock_guard<std::mutex> lock(mu_);
      cancelled_ = true;
      pid_to_kill = child_pid_;
      pending_cb_ = nullptr;
      pending_out_ = nullptr;
      pending_cap_ = 0;
    }
    space_cv_.notify_all();
    if (pid_to_kill > 0) {
      kill(pid_to_kill, SIGKILL);
    }
  }

 private:
  std::string clean_url_;
  std::string referer_;
  std::string cache_path_;
  double seek_sec_ = 0.0;

  static constexpr size_t kMaxBufferedBytes = 16u * 1024u * 1024u;
  std::mutex mu_;
  std::condition_variable space_cv_;
  std::deque<uint8_t> buffer_;
  pid_t child_pid_ = -1;
  bool eof_ = false;
  bool cancelled_ = false;
  void* pending_out_ = nullptr;
  int pending_cap_ = 0;
  CefRefPtr<CefResourceReadCallback> pending_cb_;
  IMPLEMENT_REFCOUNTING(SXStreamingTranscodeResourceHandler);
};

}  // namespace

CefRefPtr<CefResourceHandler> CreateSXMediaResourceHandler(
    CefRefPtr<CefRequest> request) {
  if (!request) return nullptr;
  std::string url = request->GetURL().ToString();
  if (url.find("__sx_tc=1") == std::string::npos &&
      url.find("__sx_meta=1") == std::string::npos) {
    return nullptr;
  }
  ParsedSXURL parsed = ParseSXMediaURL(url);
  if (!parsed.is_transcode && !parsed.is_meta) return nullptr;
  if (parsed.clean_url.rfind("http://", 0) != 0 &&
      parsed.clean_url.rfind("https://", 0) != 0) {
    return nullptr;
  }

  std::string referer = request->GetReferrerURL().ToString();
  if (parsed.is_meta) {
    return new SXMediaMetaResourceHandler(parsed.clean_url, referer);
  }

  std::string cache_path = GetCacheDir() + "/" + SHA256Hex(parsed.clean_url) + ".webm";
  struct stat st;
  if (parsed.seek_sec <= 0.05 && stat(cache_path.c_str(), &st) == 0 && st.st_size > 1024) {
    return new SXCachedMediaResourceHandler(cache_path);
  }
  return new SXStreamingTranscodeResourceHandler(
      parsed.clean_url, referer, cache_path, parsed.seek_sec);
}

SXMediaTranscodeServer& SXMediaTranscodeServer::Shared() {
  static SXMediaTranscodeServer* instance = new SXMediaTranscodeServer();
  return *instance;
}
