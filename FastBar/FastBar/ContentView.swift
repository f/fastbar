//
//  ContentView.swift
//  FastBar
//
//  Created by Fatih Kadir Akın on 3.08.2026.
//

import SwiftUI
import Charts
import AppKit

struct ContentView: View {
    @EnvironmentObject private var monitor: SpeedMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if monitor.samples.isEmpty {
                emptyState
            } else {
                timeline
                recentMeasurements
            }

            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Label("Check every", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Check interval", selection: $monitor.checkIntervalMinutes) {
                    ForEach(monitor.availableIntervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes")
                            .tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .help("Fast.com tests can use significant data at short intervals")

                Spacer()

                Button("Quit FastBar") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 390)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DOWNLOAD")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.4)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let sample = monitor.latestSample {
                        Text(sample.downloadMbps, format: .number.precision(.fractionLength(0...1)))
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("Mbps")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else if monitor.isTesting {
                        Text("Testing…")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                    } else {
                        Text("—")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                        Text("Mbps")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let sample = monitor.latestSample {
                    Text("Measured \(sample.timestamp, format: .relative(presentation: .named)) via \(sample.source.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let average = monitor.threeHourAverage {
                        Text("3-hour average: \(average.formatted(.number.precision(.fractionLength(1)))) Mbps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                } else {
                    Text("Fast.com download test")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await monitor.refresh() }
            } label: {
                if monitor.isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(monitor.isTesting)
            .help("Run speed test now")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(monitor.isTesting ? "Running the first test…" : "No measurements yet")
                .font(.headline)
            Text("FastBar will keep the last seven days of results on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 24 hours")
                    .font(.headline)
                Spacer()
                Text("\(monitor.last24Hours.count) tests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(monitor.last24Hours) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Mbps", sample.downloadMbps)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.green.opacity(0.28), .green.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Mbps", sample.downloadMbps)
                )
                .foregroundStyle(.green)
                .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                PointMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Mbps", sample.downloadMbps)
                )
                .foregroundStyle(.green)
                .symbolSize(18)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let speed = value.as(Double.self) {
                            Text(speed, format: .number.precision(.fractionLength(0)))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 145)
        }
    }

    private var recentMeasurements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)

            ForEach(monitor.recentSamples) { sample in
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)

                    Text(sample.timestamp, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(sample.downloadMbps, format: .number.precision(.fractionLength(1)))
                        .fontWeight(.semibold)
                    Text("Mbps")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SpeedMonitor(startAutomatically: false))
}
