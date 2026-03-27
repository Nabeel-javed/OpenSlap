// OnboardingView.swift — First-launch safety disclaimer and setup
// OpenSlap – macOS accelerometer-based slap detection
//
// Shows once on first launch. The user must explicitly accept the risk
// disclaimer before the app becomes functional. This is both ethically
// important (people should know the risks) and legally protective.

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var onComplete: (() -> Void)?

    @State private var acceptedRisk = false
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                warningPage.tag(1)
                setupPage.tag(2)
            }
            .tabViewStyle(.automatic)

            Divider()

            // Navigation buttons
            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation { currentPage -= 1 }
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }

                Spacer()

                if currentPage < 2 {
                    Button("Next") {
                        withAnimation { currentPage += 1 }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        settings.hasCompletedOnboarding = true
                        onComplete?()
                        dismiss()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!acceptedRisk)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to OpenSlap")
                .font(.largeTitle.bold())

            Text("Slap your MacBook.\nHear it react.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                feature(icon: "waveform.path", title: "Smart Detection",
                        text: "Multi-algorithm impact detection using your Mac's built-in accelerometer")
                feature(icon: "speaker.wave.3", title: "Dynamic Audio",
                        text: "Volume and pitch scale with slap force — gentle tap, gentle sound")
                feature(icon: "paintpalette", title: "Voice Packs",
                        text: "Choose from Pain, Sexy, Halo, or bring your own sounds")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
    }

    // MARK: - Page 2: Warning

    private var warningPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("Important Safety Information")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    warningBlock(
                        icon: "laptopcomputer.trianglebadge.exclamationmark",
                        title: "Physical Risk",
                        text: """
                        Slapping your MacBook can damage the screen, hinges, trackpad, \
                        keyboard, or internal components. Repeated impacts may cause \
                        cumulative damage that isn't immediately visible.
                        """
                    )

                    warningBlock(
                        icon: "doc.text",
                        title: "Warranty",
                        text: """
                        Physical impact damage is not covered by AppleCare or Apple's \
                        limited warranty. Using this app and slapping your Mac is \
                        entirely at your own risk and expense.
                        """
                    )

                    warningBlock(
                        icon: "shield.checkered",
                        title: "Software Safety",
                        text: """
                        The app itself does not damage your computer. It only reads \
                        the accelerometer (a passive sensor) and plays audio. The \
                        privileged daemon runs with minimal permissions and only \
                        accesses the motion sensor.
                        """
                    )

                    warningBlock(
                        icon: "eye",
                        title: "Photosensitivity",
                        text: """
                        Some visual effects may include rapid changes in brightness \
                        or color. If you are sensitive to flashing lights, enable \
                        "Reduce Motion" in System Settings > Accessibility.
                        """
                    )
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: 200)

            Toggle(isOn: $acceptedRisk) {
                Text("I understand the risks and accept full responsibility")
                    .font(.callout.bold())
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding()
    }

    // MARK: - Page 3: Setup

    private var setupPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                setupStep(number: 1, title: "Install the Daemon",
                          text: "Run the install script to set up the sensor daemon (requires admin password).")

                setupStep(number: 2, title: "Look for the Menu Bar Icon",
                          text: "OpenSlap lives in your menu bar — no dock icon. Click the hand icon to control it.")

                setupStep(number: 3, title: "Test with Mock Mode",
                          text: "Click the hammer icon in the menu to generate test slaps without hardware access.")

                setupStep(number: 4, title: "Slap Away!",
                          text: "Once the daemon is running, give your MacBook a gentle slap and enjoy the reaction.")
            }
            .padding(.horizontal, 32)

            Text("Pro tip: Start gentle. Your laptop (and wallet) will thank you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func feature(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func warningBlock(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.yellow)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setupStep(number: Int, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
