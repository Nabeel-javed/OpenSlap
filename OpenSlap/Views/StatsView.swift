// StatsView.swift — Detailed slap statistics + force leaderboard
// OpenSlap – macOS accelerometer-based slap detection

import SwiftUI

struct StatsView: View {
    @EnvironmentObject var statsTracker: StatsTracker

    var body: some View {
        VStack(spacing: 16) {
            Text("Slap Stats")
                .font(.headline)

            // Title badge
            VStack(spacing: 4) {
                Text(statsTracker.slapperTitle)
                    .font(.title3.bold())
                    .foregroundStyle(Color.accentColor)
                Text("Rank \(statsTracker.lifetimeCount) lifetime slaps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Stats grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                statCard(label: "Session", value: "\(statsTracker.sessionCount)", icon: "clock")
                statCard(label: "Lifetime", value: "\(statsTracker.lifetimeCount)", icon: "infinity")
                statCard(label: "Peak (session)", value: "\(String(format: "%.1f", statsTracker.peakForceSession))g", icon: "arrow.up")
                statCard(label: "Peak (ever)", value: "\(String(format: "%.1f", statsTracker.peakForceEver))g", icon: "star")
                statCard(label: "Average", value: "\(String(format: "%.1f", statsTracker.averageForceSession))g", icon: "equal")
                statCard(label: "Rate", value: "\(String(format: "%.0f", statsTracker.currentRate))/min", icon: "speedometer")
            }

            // Force Leaderboard
            if !statsTracker.leaderboard.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(.yellow)
                        Text("Hardest Slaps")
                            .font(.caption.bold())
                    }

                    ForEach(Array(statsTracker.leaderboard.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(index == 0 ? .yellow : .secondary)
                                .frame(width: 20, alignment: .trailing)

                            Text("\(String(format: "%.2f", entry.force))g")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(index == 0 ? .primary : .secondary)

                            Spacer()

                            Text(entry.date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if let firstDate = statsTracker.firstSlapDate {
                Text("Slapping since \(firstDate, style: .date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Copy Stats") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(statsTracker.exportStats(), forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Reset Session") {
                    statsTracker.resetSession()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func statCard(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
