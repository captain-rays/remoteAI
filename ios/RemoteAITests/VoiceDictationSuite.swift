import Foundation
import RemoteAIKit
import RemoteAITestKit

/// Hold-to-talk, driven by a scripted transcriber so the behaviour is tested
/// without a microphone or a network.
public enum VoiceDictationSuite {

    public static let suite = TestSuite(
        name: "VoiceDictationSuite",
        cases: [
            TestCase("holding the button shows the transcript as it is revised") {
                let transcriber = ScriptedTranscriber()
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }

                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                try await expectEventually("listening") {
                    await MainActor.run { dictation.isBusy }
                }

                await transcriber.emit(.partial("跑一下"))
                try await expectEventually("the partial shows") {
                    await MainActor.run { dictation.liveTranscript == "跑一下" }
                }
                await transcriber.emit(.partial("跑一下测试"))
                try await expectEventually("and its revision") {
                    await MainActor.run { dictation.liveTranscript == "跑一下测试" }
                }
            },

            TestCase("a finished sentence is kept when the next one starts") {
                // The service revises only the sentence in flight. Keeping just
                // the partial would drop everything said before it.
                let transcriber = ScriptedTranscriber()
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                await transcriber.emit(.sentence("先跑测试。"))
                await transcriber.emit(.partial("如果都过了"))

                try await expectEventually("both parts are shown") {
                    await MainActor.run { dictation.liveTranscript == "先跑测试。如果都过了" }
                }
            },

            TestCase("releasing leaves the text in the composer rather than sending it") {
                // Deliberate: this client runs Claude with permission prompts
                // bypassed, so a misheard instruction is one the Mac carries
                // out. The reader sees it first.
                let transcriber = ScriptedTranscriber()
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                await transcriber.emit(.partial("跑一下测试"))
                await MainActor.run { dictation.end() }
                await transcriber.emit(.sentence("跑一下测试。"))
                await transcriber.emit(.completed)

                try await expectEventually("the transcript settles") {
                    await MainActor.run { dictation.finishedTranscript != nil }
                }
                try expectEqual(
                    await MainActor.run { dictation.takeTranscript() }, "跑一下测试。"
                )
                try expectNil(
                    await MainActor.run { dictation.takeTranscript() },
                    "the composer takes it exactly once"
                )
                try expectEqual(await MainActor.run { dictation.state }, .idle)
            },

            TestCase("a tap that captured nothing leaves the composer alone") {
                // An empty line pushed into the composer is noise, and a tap on
                // a hold-to-talk button is an easy accident.
                let transcriber = ScriptedTranscriber()
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                await MainActor.run { dictation.end() }
                await transcriber.emit(.completed)

                try await expectEventually("back to idle") {
                    await MainActor.run { dictation.state == .idle }
                }
                try expectNil(await MainActor.run { dictation.finishedTranscript })
            },

            TestCase("the service's refusal is shown, not swallowed") {
                let transcriber = ScriptedTranscriber()
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                await transcriber.emit(.failed("Gateway:CLIENT_ERROR:Client error!"))

                try await expectEventually("the failure surfaces") {
                    await MainActor.run { dictation.state == .failed("Gateway:CLIENT_ERROR:Client error!") }
                }
                try expectFalse(await MainActor.run { dictation.isBusy })
                await MainActor.run { dictation.acknowledgeFailure() }
                try expectEqual(await MainActor.run { dictation.state }, .idle)
            },

            TestCase("a Mac with no speech set up says so in the app's own words") {
                let transcriber = FailingTranscriber(
                    error: AgentClientError.rejected("speech_not_configured")
                )
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }

                await MainActor.run { dictation.begin() }

                try await expectEventually("the reason is explained") {
                    await MainActor.run {
                        dictation.state == .failed("Speech is not set up on the Mac.")
                    }
                }
            },

            TestCase("a denied microphone points at the setting that fixes it") {
                let transcriber = FailingTranscriber(error: DictationFailure.microphoneDenied)
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }

                await MainActor.run { dictation.begin() }

                try await expectEventually("the way out is named") {
                    await MainActor.run {
                        dictation.liveTranscript.isEmpty
                            && dictation.state
                                == .failed(
                                    "RemoteAI cannot use the microphone. "
                                        + "Turn it on in Settings › RemoteAI.")
                    }
                }
            },

            TestCase("dragging off the button abandons the session") {
                let transcriber = ScriptedTranscriber()
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                await transcriber.emit(.partial("这句不要"))

                await MainActor.run { dictation.cancel() }

                try expectEqual(await MainActor.run { dictation.state }, .idle)
                try expectNil(
                    await MainActor.run { dictation.finishedTranscript },
                    "an abandoned session leaves nothing behind"
                )
                try await expectEventually("the transcriber was told") {
                    await transcriber.wasCancelled
                }
            },

            TestCase("a second press while listening is ignored") {
                // Two sessions at once would each stream the same microphone.
                let transcriber = ScriptedTranscriber()
                let dictation = await MainActor.run { VoiceDictation(transcriber: transcriber) }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                try await expectEventually("listening") {
                    await MainActor.run { dictation.isBusy }
                }

                await MainActor.run { dictation.begin() }

                try expectEqual(await transcriber.starts, 1)
            },
        ]
    )
}

/// A transcriber whose events the test decides.
private actor ScriptedTranscriber: SpeechTranscriber {
    private var continuation: AsyncStream<SpeechProtocol.Event>.Continuation?
    private(set) var starts = 0
    private(set) var wasCancelled = false

    func start() async throws -> AsyncStream<SpeechProtocol.Event> {
        starts += 1
        return AsyncStream { continuation in
            self.hold(continuation)
        }
    }

    private func hold(_ continuation: AsyncStream<SpeechProtocol.Event>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ event: SpeechProtocol.Event) async {
        // Wait for the stream to exist: `begin` opens it on its own task.
        for _ in 0..<200 where continuation == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        continuation?.yield(event)
        if case .completed = event { continuation?.finish() }
        if case .failed = event { continuation?.finish() }
    }

    func finish() async {}

    func cancel() async {
        wasCancelled = true
        continuation?.finish()
    }
}

private actor FailingTranscriber: SpeechTranscriber {
    private let error: Error
    init(error: Error) { self.error = error }
    func start() async throws -> AsyncStream<SpeechProtocol.Event> { throw error }
    func finish() async {}
    func cancel() async {}
}

/// The service does not always answer. These pin what the button does then,
/// which is the difference between "nothing was heard" and a control that
/// reads "Listening…" for ever.
public enum VoiceDictationTimeoutSuite {
    public static let suite = TestSuite(
        name: "VoiceDictationTimeoutSuite",
        cases: [
            TestCase("a release the service never answers stops listening and says why") {
                // Seen for real: with no audio captured the service has
                // nothing to finish and sends nothing at all.
                let transcriber = SilentTranscriber()
                let dictation = await MainActor.run {
                    VoiceDictation(
                        transcriber: transcriber, settleWithin: .milliseconds(150)
                    )
                }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                try await expectEventually("listening") {
                    await MainActor.run { dictation.isBusy }
                }

                await MainActor.run { dictation.end() }

                try await expectEventually("it gives up and explains") {
                    await MainActor.run { dictation.state == .failed("Nothing was heard.") }
                }
                try expectFalse(await MainActor.run { dictation.isBusy })
                try await expectEventually("and lets go of the microphone") {
                    await transcriber.wasCancelled
                }
            },

            TestCase("what was heard is kept even when the service goes quiet") {
                // A dropped connection mid-sentence should not throw away the
                // words already recognised.
                let transcriber = SilentTranscriber()
                let dictation = await MainActor.run {
                    VoiceDictation(
                        transcriber: transcriber, settleWithin: .milliseconds(150)
                    )
                }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                await transcriber.emit(.partial("跑一下测试"))
                await MainActor.run { dictation.end() }

                try await expectEventually("the words survive") {
                    await MainActor.run { dictation.finishedTranscript == "跑一下测试" }
                }
                try expectEqual(await MainActor.run { dictation.state }, .idle)
            },

            TestCase("a hold nobody ended is stopped rather than left open") {
                // A finger that never lifted, or a gesture the system dropped,
                // must not hold the microphone open.
                let transcriber = SilentTranscriber()
                let dictation = await MainActor.run {
                    VoiceDictation(
                        transcriber: transcriber,
                        settleWithin: .seconds(30),
                        holdLimit: .milliseconds(150)
                    )
                }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)

                try await expectEventually("the hold is cut short") {
                    await MainActor.run {
                        dictation.state == .failed("Stopped listening after a minute.")
                    }
                }
                try await expectEventually("and the microphone released") {
                    await transcriber.wasCancelled
                }
            },
        ]
    )
}

/// Opens a session and then says nothing more, whatever it is told.
private actor SilentTranscriber: SpeechTranscriber {
    private var continuation: AsyncStream<SpeechProtocol.Event>.Continuation?
    private(set) var wasCancelled = false

    func start() async throws -> AsyncStream<SpeechProtocol.Event> {
        AsyncStream { continuation in self.hold(continuation) }
    }

    private func hold(_ continuation: AsyncStream<SpeechProtocol.Event>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ event: SpeechProtocol.Event) async {
        for _ in 0..<200 where continuation == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        continuation?.yield(event)
    }

    func finish() async {}

    func cancel() async {
        wasCancelled = true
        continuation?.finish()
    }
}

/// "Nothing was heard" is true of three different faults, and they need
/// different things done about them. These pin which sentence each produces —
/// written after a real device reported the same useless message for all of
/// them.
public enum DictationDiagnosisSuite {
    public static let suite = TestSuite(
        name: "DictationDiagnosisSuite",
        cases: [
            TestCase("a service that never acknowledged the session says so") {
                try expectEqual(
                    VoiceDictation.explain(
                        DictationDiagnosis(audioFramesSent: 12),
                        sessionOpened: false, fallback: "Nothing was heard."
                    ),
                    "The speech service did not answer."
                )
            },

            TestCase("a microphone that yielded nothing is named as the cause") {
                // The audio path is the phone's own, and this is the sentence
                // that sends the reader to the right place.
                try expectEqual(
                    VoiceDictation.explain(
                        DictationDiagnosis(audioFramesSent: 0),
                        sessionOpened: true, fallback: "Nothing was heard."
                    ),
                    "No sound reached the microphone."
                )
            },

            TestCase("audio that was sent and made nothing of says how much") {
                // The frame count is what distinguishes "we sent it silence"
                // from "we sent it speech and it disagreed".
                try expectEqual(
                    VoiceDictation.explain(
                        DictationDiagnosis(audioFramesSent: 34),
                        sessionOpened: true, fallback: "Nothing was heard."
                    ),
                    "The speech service heard nothing in 34 frames of audio."
                )
            },

            TestCase("a dropped connection is reported as itself") {
                // Swallowing the send error was how a dropped connection came
                // out as "nothing was heard".
                try expectEqual(
                    VoiceDictation.explain(
                        DictationDiagnosis(
                            audioFramesSent: 3, lastAudioError: "Socket is not connected"
                        ),
                        sessionOpened: true, fallback: "Nothing was heard."
                    ),
                    "The connection to the speech service dropped: Socket is not connected"
                )
            },

            TestCase("a transcriber that keeps no account is not made to invent one") {
                // `nil` frames is not zero frames, and claiming the microphone
                // was silent on that basis would be a guess.
                try expectEqual(
                    VoiceDictation.explain(
                        DictationDiagnosis(),
                        sessionOpened: true, fallback: "Nothing was heard."
                    ),
                    "Nothing was heard."
                )
            },

            TestCase("the real reason replaces the placeholder on screen") {
                let transcriber = CountingSilentTranscriber(framesSent: 0)
                let dictation = await MainActor.run {
                    VoiceDictation(
                        transcriber: transcriber, settleWithin: .milliseconds(120)
                    )
                }
                await MainActor.run { dictation.begin() }
                await transcriber.emit(.started)
                try await expectEventually("listening") {
                    await MainActor.run { dictation.isBusy }
                }
                await MainActor.run { dictation.end() }

                try await expectEventually("the microphone is named") {
                    await MainActor.run {
                        dictation.state == .failed("No sound reached the microphone.")
                    }
                }
            },
        ]
    )
}

/// Says nothing back, but keeps an account of the audio it was given.
private actor CountingSilentTranscriber: SpeechTranscriber {
    private let framesSent: Int
    private var continuation: AsyncStream<SpeechProtocol.Event>.Continuation?

    init(framesSent: Int) { self.framesSent = framesSent }

    func start() async throws -> AsyncStream<SpeechProtocol.Event> {
        AsyncStream { continuation in self.hold(continuation) }
    }

    private func hold(_ continuation: AsyncStream<SpeechProtocol.Event>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ event: SpeechProtocol.Event) async {
        for _ in 0..<200 where continuation == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        continuation?.yield(event)
    }

    func finish() async {}
    func cancel() async { continuation?.finish() }
    func diagnosis() async -> DictationDiagnosis {
        DictationDiagnosis(audioFramesSent: framesSent)
    }
}
