//
//  ScrollInterceptor.swift
//  UnnaturalScrollWheels
//
//  Created by Theron Tjapkes on 7/25/20.
//  Copyright © 2020 Theron Tjapkes. All rights reserved.
//

import Foundation
import CoreGraphics
import Cocoa

// MARK: - MultitouchSupport private framework interop
//
// These mirror the (undocumented) structs the MultitouchSupport framework
// hands to a contact-frame callback. We only read `state` (4 == a finger is
// actively touching the surface), but the whole layout has to match so the
// offset of `state` is correct.
struct MTPoint { var x: Float; var y: Float }
struct MTVector { var x: Float; var y: Float }

struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalizedX: Float // Split MTPoint into two Floats
    var normalizedY: Float
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var unknown4X: Float   // Split MTVector
    var unknown4Y: Float
    var unknown5X: Float
    var unknown5Y: Float
    var unknown6: Float
}

// MARK: - Tap-to-drag state machine
//
// Windows-style "tap to click and drag": tap once, then tap again and hold to
// begin dragging. Unlike macOS's built-in "Dragging" (which keeps the mouse
// button held after you lift your finger until you tap again or a timeout
// passes), lifting the finger here ends the drag *immediately*.
private enum TapDragState {
    case idle                               // nothing in progress
    case firstTouch(TimeInterval)           // one finger down — maybe the first tap
    case waitingForSecondTouch(TimeInterval)// first tap released — waiting for the drag tap
    case dragging                           // second tap held down — a synthetic drag is live
}

// The maximum time a finger may rest before a touch counts as a "tap" rather
// than a slow press/hold.
private let tapMaxDuration: TimeInterval = 0.3
// The maximum gap between the first tap lifting and the second tap landing for
// the pair to register as a double-tap (macOS default is ~0.3s).
private let doubleTapThreshold: TimeInterval = 0.3

// If a drag is live and we haven't seen a contact frame for this long, assume
// the lift frame was dropped and force-release. Frames stream at ~90-125Hz
// while any finger is touching (even held still), so this is unambiguous.
private let dragReleaseTimeout: TimeInterval = 0.15

// Global state for the C-convention MultitouchSupport callback (which cannot
// capture context).
private var tapDragState: TapDragState = .idle
private var previousTouchCount: Int = 0

// Failsafe bookkeeping: MultitouchSupport stops delivering frames once all
// fingers are off the pad. If the final "no contacts" frame is dropped (it
// occasionally is, e.g. on a fast flick), we would never observe the lift and
// the synthetic drag would stay stuck holding the button. Track when we last
// saw a finger so a watchdog can release the button if touch data goes silent
// mid-drag. Guarded by `stateLock` because the watchdog runs off-thread.
private var lastContactTime: UInt64 = 0
private var stateLock = os_unfair_lock()

class ScrollInterceptor {

    static let shared = ScrollInterceptor()

    // MARK: Tap-to-drag callback

    // Called by MultitouchSupport on every trackpad frame. Counts the fingers
    // actively touching the surface and drives the tap-drag state machine.
    let mtCallback: @convention(c) (Int32, UnsafeRawPointer?, Int32, Double, Int32) -> Int32 = {
        (device, contactsPtr, fingerCount, timestamp, frame) in

        var touchCount = 0
        if let ptr = contactsPtr {
            let contacts = ptr.assumingMemoryBound(to: MTContact.self)
            for i in 0..<Int(fingerCount) where contacts[i].state == 4 {
                touchCount += 1
            }
        }

        os_unfair_lock_lock(&stateLock)
        if touchCount >= 1 {
            lastContactTime = mach_absolute_time()
        }
        let previous = previousTouchCount
        previousTouchCount = touchCount
        ScrollInterceptor.handleTouch(count: touchCount, previous: previous, time: timestamp)
        os_unfair_lock_unlock(&stateLock)
        return 0
    }

    // Pure state-machine step, kept separate from the C callback so the logic
    // is easy to follow (and test). `time` is the frame timestamp in seconds.
    static func handleTouch(count: Int, previous: Int, time: TimeInterval) {
        // More than one finger cancels any tap-drag gesture. If a drag was live,
        // release it first so we never leave the mouse button stuck down.
        if count > 1 {
            if case .dragging = tapDragState {
                postMouse(.leftMouseUp)
            }
            tapDragState = .idle
            return
        }

        let touchDown = (previous == 0 && count == 1)
        let touchUp   = (previous >= 1 && count == 0)

        switch tapDragState {
        case .idle:
            if touchDown {
                tapDragState = .firstTouch(time)
            }

        case .firstTouch(let start):
            if touchUp {
                // A quick tap arms the double-tap window; a long press is not a tap.
                if time - start <= tapMaxDuration {
                    tapDragState = .waitingForSecondTouch(time)
                } else {
                    tapDragState = .idle
                }
            }

        case .waitingForSecondTouch(let releaseTime):
            if touchDown {
                if time - releaseTime <= doubleTapThreshold {
                    // Second tap within the window → begin the drag.
                    postMouse(.leftMouseDown)
                    tapDragState = .dragging
                } else {
                    // Too slow to be a double-tap → treat as a fresh first tap.
                    tapDragState = .firstTouch(time)
                }
            }

        case .dragging:
            if touchUp {
                // Windows behaviour: releasing the finger ends the drag at once.
                postMouse(.leftMouseUp)
                tapDragState = .idle
            } else if count == 1 {
                // Keep the drag alive as the finger (and cursor) move.
                postMouse(.leftMouseDragged)
            }
        }
    }

    // MARK: Stuck-drag watchdog

    private static let timebase: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    private static func secondsSince(_ machTime: UInt64) -> TimeInterval {
        let elapsed = mach_absolute_time() &- machTime
        let nanos = elapsed * UInt64(timebase.numer) / UInt64(timebase.denom)
        return TimeInterval(nanos) / 1_000_000_000
    }

    private var dragWatchdog: DispatchSourceTimer?

    // If the drag is live but no contact frame has arrived recently, the lift
    // frame was dropped — release the button so the drag can't get stuck.
    private func startDragWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler {
            os_unfair_lock_lock(&stateLock)
            if case .dragging = tapDragState,
               lastContactTime != 0,
               ScrollInterceptor.secondsSince(lastContactTime) > dragReleaseTimeout {
                ScrollInterceptor.postMouse(.leftMouseUp)
                tapDragState = .idle
                // Frames stopped without a 0-count frame, so the stale count
                // would otherwise mask the next touch-down transition.
                previousTouchCount = 0
            }
            os_unfair_lock_unlock(&stateLock)
        }
        timer.resume()
        dragWatchdog = timer
    }

    // Post a synthetic left-button mouse event at the current cursor location.
    private static func postMouse(_ type: CGEventType) {
        let point = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source,
                            mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: Scroll wheel inversion

    // Where the magic happens
    let scrollEventCallback: CGEventTapCallBack = { (proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon) in
        //        // Debugging
        //        // Usually 0 if scroll wheel unless Logitech Options or similar interferes
        //        print("Continuous: ", event.getIntegerValueField(.scrollWheelEventIsContinuous))
        //        // Undocumented values, but appear to only be non-zero for trackpads?
        //        print("MomentumPhase: ", event.getDoubleValueField(.scrollWheelEventMomentumPhase))
        //        print("ScrollCount: ", event.getDoubleValueField(.scrollWheelEventScrollCount))
        //        print("ScrollPhase: ", event.getDoubleValueField(.scrollWheelEventScrollPhase))

        var isWheel: Bool = true
        if !Options.shared.alternateDetectionMethod {
            // scrollWheelEventIsContinuous will be 0 for mice and 1 for trackpads
            // probably faster than the alternate detection method since only one comparison
            if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
                isWheel = false
            }
        } else {
            // Undocumented values but seem to be non-zero only for trackpads
            if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 ||
                event.getDoubleValueField(.scrollWheelEventScrollCount) != 0.0 ||
                event.getDoubleValueField(.scrollWheelEventScrollPhase) != 0.0 {
                isWheel = false
            }
        }

        if isWheel {
            // Invert the scroll event
            if Options.shared.invertVerticalScroll {
                event.setIntegerValueField(
                    .scrollWheelEventDeltaAxis1, value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            }
            if Options.shared.invertHorizontalScroll {
                event.setIntegerValueField(
                    .scrollWheelEventDeltaAxis2, value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            }
            // Disable scroll acceleration
            if Options.shared.disableScrollAccel {
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: event.getIntegerValueField(.scrollWheelEventDeltaAxis1).signum() * Options.shared.scrollLines)
            }
        }
        // pass the event to the system
        return Unmanaged.passUnretained(event)
    }

    // MARK: Setup

    // Register with the MultitouchSupport framework so `mtCallback` is invoked
    // on every trackpad frame. Loaded dynamically because it's a private
    // framework with no public headers.
    private func startTapToDrag() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSym = dlsym(handle, "MTDeviceCreateDefault"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart") else {
            NSLog("UnnaturalScrollWheels: could not load MultitouchSupport; tap-to-drag disabled")
            return
        }

        typealias CreateFn = @convention(c) () -> UnsafeRawPointer?
        typealias RegisterFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> Void
        typealias StartFn = @convention(c) (UnsafeRawPointer, Int32) -> Void

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        let start = unsafeBitCast(startSym, to: StartFn.self)

        guard let device = create() else {
            NSLog("UnnaturalScrollWheels: no multitouch device; tap-to-drag disabled")
            return
        }
        let callbackPtr = unsafeBitCast(mtCallback, to: UnsafeRawPointer.self)
        register(device, callbackPtr, nil)
        start(device, 0)
        startDragWatchdog()
    }

    // Intercept scroll wheel events (and start tap-to-drag if enabled).
    func interceptScroll() {
        if Options.shared.windowsStyleTapDrag {
            startTapToDrag()
        }

        DispatchQueue.global(qos: .userInteractive).async {
            var eventTap: CFMachPort?
            var runLoopSource: CFRunLoopSource?

            eventTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .tailAppendEventTap,
                options: .defaultTap,
                // Mask to select only scroll wheel events
                eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                callback: self.scrollEventCallback,
                userInfo: nil
            )
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
            CGEvent.tapEnable(tap: eventTap!, enable: true)
            CFRunLoopRun()
        }
    }
}
