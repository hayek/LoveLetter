#if os(macOS)
import Foundation

enum CLIOutput {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":"encoding_failed","message":"Could not encode the response."}}"#
        }
        return text
    }
}

/// Human-readable rendering for `--text`. Explicitly NOT a stable contract — the skill tells
/// agents to use the JSON default and never parse this.
enum CLIText {
    private static let titleWidth = 60

    private static func clip(_ text: String, _ width: Int) -> String {
        text.count <= width ? text : String(text.prefix(width - 1)) + "…"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func render(products: [ProductSummary]) -> String {
        guard !products.isEmpty else { return "No products configured." }
        return products.map { product in
            """
            \(product.displayName)  [\(product.repo)]
              feedback: \(product.feedbackCount)   tasks: \(product.taskCount)
              code repo: \(product.connectedRepo ?? "—")
              id: \(product.id)
            """
        }.joined(separator: "\n\n")
    }

    static func render(feedback items: [FeedbackItem]) -> String {
        guard !items.isEmpty else { return "No matching feedback." }
        return items.map { item in
            let tasks = item.tasks.isEmpty ? "" : "  → " + item.tasks.map { "#\($0.number)" }.joined(separator: " ")
            let rating = item.rating.map { " \($0)★" } ?? ""
            return (item.unread == true ? "•" : " ") + "#\(pad(String(item.number), 5)) \(pad(item.state, 7))"
                 + "\(pad(clip(item.app ?? "—", 18), 19))"
                 + "\(clip(item.title, titleWidth))\(rating)\(tasks)"
        }.joined(separator: "\n")
    }

    static func render(detail: FeedbackDetail) -> String {
        var lines = [
            "#\(detail.number)  \(detail.title)",
            "\(detail.state) · \(detail.source) · \(detail.app ?? "—") \(detail.appVersion ?? "")",
            "\(detail.device ?? "—") · \(detail.os ?? "—") · \(CLIOutput.iso8601.string(from: detail.createdAt))",
        ]
        if let email = detail.email { lines.append("reporter: \(email)") }
        if !detail.labels.isEmpty { lines.append("labels: \(detail.labels.joined(separator: ", "))") }
        if !detail.tasks.isEmpty {
            lines.append("tasks: " + detail.tasks.map { "#\($0.number) \($0.status)" }.joined(separator: ", "))
        }
        if let thread = detail.thread {
            lines.append("thread: \(thread.messageCount) messages, last \(thread.lastDirection ?? "—")")
        }
        if !detail.attachments.isEmpty {
            lines.append("attachments: " + detail.attachments.map(\.filename).joined(separator: ", "))
        }
        lines.append("")
        lines.append(detail.description)
        lines.append("")
        lines.append(detail.url)
        return lines.joined(separator: "\n")
    }

    static func render(tasks: [TaskItemDTO]) -> String {
        guard !tasks.isEmpty else { return "No matching tasks." }
        return tasks.map { task in
            let feedback = task.feedback.isEmpty ? "" : "  ← " + task.feedback.map { "#\($0)" }.joined(separator: " ")
            return "#\(pad(String(task.number), 5)) \(pad(task.status, 12))\(pad(task.priority, 6))"
                 + "\(clip(task.title, titleWidth))\(feedback)"
        }.joined(separator: "\n")
    }

    static func render(taskDetail: TaskDetail) -> String {
        var lines = [
            "#\(taskDetail.number)  \(taskDetail.title)",
            "\(taskDetail.status) · \(taskDetail.priority) · \(taskDetail.milestone ?? "no version")",
        ]
        if !taskDetail.feedback.isEmpty {
            lines.append("addresses: " + taskDetail.feedback
                .map { "#\($0.number) \(clip($0.title, 40))" }.joined(separator: "\n           "))
        }
        lines.append("")
        lines.append(taskDetail.notes.isEmpty ? "(no notes)" : taskDetail.notes)
        lines.append("")
        lines.append(taskDetail.url)
        return lines.joined(separator: "\n")
    }

    static func render(versions: [VersionItem]) -> String {
        guard !versions.isEmpty else { return "No versions." }
        return versions.map { version in
            "\(pad(clip(version.name, 14), 15))\(pad(version.state, 10))"
                + "\(pad("\(version.doneCount)/\(version.taskCount) done", 13))"
                + clip(version.releaseTitle ?? "", titleWidth)
        }.joined(separator: "\n")
    }

    static func render(versionDetail detail: VersionDetailDTO) -> String {
        let version = detail.version
        var lines = ["\(version.name)  \(version.releaseTitle ?? "")",
                     "\(version.state) · \(version.doneCount)/\(version.taskCount) tasks done"
                        + " · releases to \(detail.releaseRepo)"]
        if let releasedAt = version.releasedAt {
            lines.append("released \(CLIOutput.iso8601.string(from: releasedAt)) \(version.releaseTag ?? "")")
        }
        lines.append("")
        lines.append(detail.changelog.isEmpty ? "(no changelog)" : detail.changelog)
        lines.append("")
        lines.append(detail.tasks.isEmpty ? "No tasks." : render(tasks: detail.tasks))
        lines.append("")
        lines.append(render(recipients: detail.recipients))
        if !detail.sentEmails.isEmpty {
            lines.append("")
            lines.append("sent: " + detail.sentEmails.map { "\($0.email) (\($0.status))" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    static func render(recipients: [ReleaseRecipientDTO]) -> String {
        guard !recipients.isEmpty else { return "No release recipients." }
        return recipients.map { recipient in
            let feedback = recipient.feedback.map { "#\($0)" }.joined(separator: " ")
            return "\(pad(recipient.email, 32)) \(feedback)\(recipient.alreadyEmailed ? "  (already emailed)" : "")"
        }.joined(separator: "\n")
    }

    static func render(templates: [TemplateDTO]) -> String {
        guard !templates.isEmpty else { return "No reply templates." }
        return templates.map { "\($0.title)\n  \(clip($0.body.replacingOccurrences(of: "\n", with: " "), 76))" }
            .joined(separator: "\n\n")
    }

    static func render(accounts: AccountsDTO) -> String {
        var lines = ["GitHub: " + (accounts.github.isEmpty ? "none" : accounts.github.map(\.login).joined(separator: ", "))]
        lines.append("Mail:" + (accounts.mail.isEmpty ? " none" : ""))
        for mail in accounts.mail {
            var tags = [mail.service]
            if mail.isDefaultSender { tags.append("default sender") }
            if let product = mail.feedbackInboxFor { tags.append("inbox for \(product)") }
            lines.append("  \(mail.address)  (\(tags.joined(separator: ", ")))")
        }
        return lines.joined(separator: "\n")
    }

    /// A write's result, one top-level field per line.
    static func render(writeResult: Any?, warnings: [String]) -> String {
        var lines = ["OK"]
        if let object = writeResult as? [String: Any] {
            for key in object.keys.sorted() {
                lines.append("\(key): \(describe(object[key] ?? NSNull()))")
            }
        }
        lines += warnings.map { "warning: \($0)" }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let array as [Any]: return array.map(describe).joined(separator: ", ")
        case let object as [String: Any]:
            return "{" + object.keys.sorted().map { "\($0): \(describe(object[$0] ?? NSNull()))" }
                .joined(separator: ", ") + "}"
        case is NSNull: return "—"
        // JSONSerialization hands booleans back as NSNumber, which would print as 1/0.
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "yes" : "no"
        default: return "\(value)"
        }
    }
}
#endif
