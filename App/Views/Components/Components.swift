import DoxiCore
import SwiftUI

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Label(confidence.shortName, systemImage: confidence.symbol)
            .font(.caption)
            .foregroundStyle(confidence.tint)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(confidence.displayName)
    }
}

extension Confidence {
    var shortName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .unverified: return "Unverified"
        }
    }

    var symbol: String {
        switch self {
        case .high: return "checkmark.circle"
        case .medium: return "exclamationmark.circle"
        case .low: return "exclamationmark.triangle"
        case .unverified: return "questionmark.diamond"
        }
    }

    var tint: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low, .unverified: return .red
        }
    }
}

struct VerificationBadge: View {
    let status: VerificationStatus

    var body: some View {
        switch status {
        case .confirmed: Label("Confirmed", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
        case .edited: Label("Edited", systemImage: "pencil.circle.fill").font(.caption).foregroundStyle(.blue)
        case .rejected: Label("Rejected", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
        case .pending: EmptyView()
        }
    }
}

struct ObligationStatusBadge: View {
    let status: ObligationStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    var tint: Color {
        switch status {
        case .overdue: return .red
        case .pending, .upcoming: return .orange
        case .received, .completed: return .green
        case .cancelled, .dismissed: return .secondary
        }
    }
}

struct ProcessingBadge: View {
    let status: ProcessingStatus

    var body: some View {
        HStack(spacing: 4) {
            if status.isWorking { ProgressView().controlSize(.mini) }
            Text(status.displayName)
        }
        .font(.caption)
        .foregroundStyle(status == .failed ? .red : status == .needsReview ? .orange : .secondary)
    }
}

struct SourceQuoteView: View {
    let source: SourceSpan

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(source.pageLabel)\(source.match == .exact || source.match == .normalized ? "" : " · approximate match")")
                .font(.caption2).foregroundStyle(.secondary)
            Text("“\(source.quote.collapsedWhitespace)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows where this was found in the document")
    }
}

extension String {
    var collapsedWhitespace: String { split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}

extension FinancialDirection {
    var symbol: String {
        switch self {
        case .owedToMe: return "arrow.down.left.circle"
        case .iOwe: return "arrow.up.right.circle"
        case .notMine: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension ObligationCategory {
    var symbol: String {
        switch self {
        case .payment: return "indianrupeesign.circle"
        case .renewal: return "arrow.triangle.2.circlepath"
        case .noticeDeadline: return "bell.badge"
        case .contractEnd: return "calendar.badge.exclamationmark"
        case .deliverable: return "shippingbox"
        case .deadline: return "clock"
        case .other: return "checklist"
        }
    }
}

extension CalendarDate {
    /// "15 Oct" for this year, "15 Oct 2027" otherwise.
    var shortDisplay: String {
        year == CalendarDate.today().year ? "\(day) \(CalendarDate.monthAbbreviations[month - 1])" : mediumString
    }

    var foundationDate: Date { date(hour: 12) }
}

/// Shows an obligation in lists.
struct ObligationRow: View {
    let obligation: ObligationRecord
    var showDocument = true

    var body: some View {
        let status = obligation.status()
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                if let due = obligation.dueDate {
                    Text("\(due.day)").font(.title3.weight(.semibold).monospacedDigit())
                    Text(CalendarDate.monthAbbreviations[due.month - 1].uppercased()).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Image(systemName: obligation.category.symbol).font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(obligation.title).font(.body).lineLimit(2)
                if showDocument, let who = obligation.counterparty ?? obligation.document?.title {
                    Text(who).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    ObligationStatusBadge(status: status)
                    if obligation.isPayment && obligation.direction != .unknown {
                        Label(obligation.direction.displayName, systemImage: obligation.direction.symbol)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if obligation.recurrence != nil {
                        Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Recurring")
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
