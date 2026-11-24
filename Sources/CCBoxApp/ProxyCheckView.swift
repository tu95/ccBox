import SwiftUI
import CCBoxCore

struct ProxyCheckPopoverView: View {
    let report: ProxyCheckReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                let color: Color = report.allPassed ? .green : (report.hasFailure ? .red : .orange)
                Image(systemName: report.allPassed ? "checkmark.shield.fill" : (report.hasFailure ? "exclamationmark.shield.fill" : "shield.lefthalf.filled"))
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.allPassed ? "全部检测通过 · 代理环境就绪" : (report.hasFailure ? "检测到风险项 · 请检查节点" : "大部分通过 · 存在提醒项"))
                        .font(.system(size: 13, weight: .semibold))
                    Text("已通过 \(report.passedCount) / \(report.totalCount) 项 · 纯代理环境覆盖检测")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let ip = report.exitIP {
                HStack(spacing: 8) {
                    Text(ip)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    let meta = [report.city, report.country, report.asn, report.isp]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 9) {
                ForEach(report.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        statusIcon(for: item.status)
                            .font(.system(size: 12))
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(item.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 390)
    }

    @ViewBuilder
    private func statusIcon(for status: ProxyCheckItem.Status) -> some View {
        switch status {
        case .pass:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct ProxyCheckSidebarCard: View {
    let report: ProxyCheckReport

    var body: some View {
        let accent: Color = report.allPassed ? .green : (report.hasFailure ? .red : .orange)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: report.allPassed ? "checkmark.shield.fill" : (report.hasFailure ? "exclamationmark.shield.fill" : "shield.lefthalf.filled"))
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                Text(report.allPassed ? "环境检测通过 \(report.passedCount)/\(report.totalCount)" : "代理环境检测 \(report.passedCount)/\(report.totalCount)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent)
                Spacer()
                if let ip = report.exitIP {
                    Text(ip)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(report.items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(dotColor(for: item.status))
                            .frame(width: 5.5, height: 5.5)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(item.detail)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent.opacity(0.24), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func dotColor(for status: ProxyCheckItem.Status) -> Color {
        switch status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}
