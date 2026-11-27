// Toggles Safarium's Tab Overview (app must run with SAFARIUM_FREEZE_DEBUG=1). Usage: swift scripts/flicker/toggle-overview.swift
import Foundation
DistributedNotificationCenter.default().postNotificationName(Notification.Name("SafariumDebugToggleTabOverview"), object: nil, userInfo: nil, deliverImmediately: true)
