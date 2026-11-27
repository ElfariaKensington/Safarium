import sys
def unwrap(path, markers):
    s=open(path).read(); out=[]; i=0; n=0
    while True:
        j=s.find('XCTExpectFailure(', i)
        if j<0: out.append(s[i:]); break
        k=s.find(') {', j); header=s[j:k]
        if not any(m in header for m in markers): out.append(s[i:k+3]); i=k+3; continue
        ls=s.rfind('\n',0,j)+1; depth=0; p=k+2
        while True:
            c=s[p]
            if c=='{': depth+=1
            elif c=='}':
                depth-=1
                if depth==0: break
            p+=1
        body=s[k+3:p]; lines=[l[4:] if l.startswith('    ') else l for l in body.split('\n')]
        out.append(s[i:ls]); out.append('\n'.join(lines).strip('\n')); i=p+1; n+=1
    open(path,'w').write(''.join(out)); return n
if __name__=='__main__':
    print(unwrap(sys.argv[1], sys.argv[2:]))
