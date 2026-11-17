import CoreGraphics
import Foundation
import Testing
@testable import Drem

@Suite struct IslandGestureTests {
    @Test func followsFingersBeforeReleaseAndShortCancelledGesturesNeverCommit() throws {
        for intent: IslandSwipe.Intent in [.hide, .restore] {
            var swipe = IslandSwipe()
            let first = swipe.consume(x: 12, y: 0, inverted: false, precise: true,
                timestamp: 1, phase: .began, momentum: false, intent: intent)
            let f1 = try #require(first.feedback)
            #expect(f1.progress > 0 && f1.progress < 1)
            #expect(f1.offsetX > 0 && f1.offsetX < 13)
            #expect(first.resolution == nil)
            #expect(swipe.finish(at: 1.3).resolution == .cancel)
            let full = swipe.consume(x: -80, y: 0, inverted: false, precise: true,
                timestamp: 2, phase: .began, momentum: false, intent: intent)
            #expect(full.feedback?.ready == true)
            #expect(full.thresholdCrossed)
            #expect(swipe.finish(at: 2.01, cancelled: true).resolution == .cancel)
            #expect(swipe.feedback == nil)
        }
    }

    @Test func reversalFallsBackAndThresholdHapticOnlyCrossesOnce() {
        var swipe = IslandSwipe()
        #expect(swipe.consume(x: 48, y: 0, inverted: false, precise: true,
            timestamp: 1, phase: .began, momentum: false, intent: .hide).thresholdCrossed)
        #expect(!swipe.consume(x: 6, y: 0, inverted: false, precise: true,
            timestamp: 1.1, phase: .changed, momentum: false, intent: .hide).thresholdCrossed)
        #expect(swipe.consume(x: -47, y: 0, inverted: false, precise: true,
            timestamp: 1.2, phase: .changed, momentum: false, intent: .hide).feedback?.ready == false)
        #expect(swipe.finish(at: 1.21).resolution == .cancel)
    }

    @Test func naturalScrollingChangesRawSignNotVisualDirectionAndOverscrollIsBounded() throws {
        for inverted in [false, true] {
            var swipe = IslandSwipe()
            let feedback = try #require(swipe.consume(x: inverted ? -10000 : 10000, y: 0,
                inverted: inverted, precise: true, timestamp: 1, phase: .began,
                momentum: false, intent: .hide).feedback)
            #expect(feedback.offsetX > 0 && feedback.offsetX <= 13)
            #expect(feedback.scaleX >= 0.9)
            #expect(feedback.scaleY >= 0.78)
            #expect(feedback.offsetY <= 0, "Never detach the top edge downwards")
        }
    }

    @Test func capturedGestureSurvivesPointerLeavingButDoesNotCaptureOffTargetStarts() {
        var swipe = IslandSwipe()
        _ = swipe.consume(x: 20, y: 0, inverted: false, precise: true,
            timestamp: 1, phase: .began, momentum: false, intent: .hide)
        #expect(swipe.consume(x: 30, y: 0, inverted: false, precise: true,
            timestamp: 1.1, phase: .changed, momentum: false, intent: nil).captured)
        #expect(swipe.finish(at: 1.2).resolution == .commit(.hide))
        _ = swipe.consume(x: 20, y: 0, inverted: false, precise: true,
            timestamp: 2, phase: .began, momentum: false, intent: nil)
        #expect(!swipe.consume(x: 30, y: 0, inverted: false, precise: true,
            timestamp: 2.1, phase: .changed, momentum: false, intent: .hide).captured)
        #expect(swipe.finish(at: 2.2).resolution == nil)
    }

    @Test func quickIntentionalFlickCommitsButSlowShortDragAndStaleVelocityDoNot() {
        for release in [1.025, 1.5] {
            var swipe = IslandSwipe()
            _ = swipe.consume(x: 8, y: 0, inverted: false, precise: true,
                timestamp: 1, phase: .began, momentum: false, intent: .restore)
            _ = swipe.consume(x: 15, y: 0, inverted: false, precise: true,
                timestamp: 1.02, phase: .changed, momentum: false, intent: .restore)
            #expect(swipe.finish(at: release).resolution == (release < 1.1 ? .commit(.restore) : .cancel))
        }
    }

    @Test func axisLockPreventsDiagonalWrongDirectionAndResetDiscardsInterruptedGesture() {
        var swipe = IslandSwipe()
        _ = swipe.consume(x: 0, y: -20, inverted: false, precise: true,
            timestamp: 1, phase: .began, momentum: false, intent: .hide)
        #expect(swipe.consume(x: 100, y: 0, inverted: false, precise: true,
            timestamp: 1.1, phase: .changed, momentum: false, intent: .hide).feedback?.progress == 0)
        swipe.reset()
        #expect(swipe.feedback == nil)
        #expect(!swipe.consume(x: 100, y: 0, inverted: false, precise: true,
            timestamp: 1.2, phase: .changed, momentum: false, intent: .hide).captured)
        #expect(!swipe.finish(at: 1.3).captured)
    }
}
