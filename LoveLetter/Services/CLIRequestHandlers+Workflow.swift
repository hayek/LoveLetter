#if os(macOS)
import Foundation
import SwiftData

/// `tasks update|delete`, `feedback mark-read|triage`, `respond --delete` and the template
/// writes — the app side, each calling what the matching UI control calls.
extension CLIRequestHandlers {

    // MARK: - tasks update / delete

    /// Reads the task LIVE from GitHub and refuses anything without the task label — the same
    /// guard `tasks link` uses, so a feedback number can never be edited or deleted as a task.
    static func liveTask(_ number: Int, config: ProductConfig, token: String,
                         deps: Dependencies) async throws -> FetchedIssue {
        let live: FetchedIssue
        do {
            live = try await deps.writer.fetchIssue(owner: config.owner, repo: config.repo,
                                                    number: number, token: token)
        } catch {
            throw CLIError.notFound(code: "task_not_found",
                                    message: "Could not read task #\(number): \(error.localizedDescription)")
        }
        guard live.labels.contains(LoveLetterLabels.task) else {
            throw CLIError.notFound(code: "task_not_found", message: "#\(number) is not a task.",
                                    hint: "It has no \(LoveLetterLabels.task) label.")
        }
        return live
    }

    /// `TaskDetailView`'s Apply: one PATCH of title, notes, status, priority and version.
    /// Fields not passed keep their live values, and the machine-managed feedback block is
    /// preserved from the live body.
    static func updateTask(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let config = try resolveConfig(request, cloud: deps.cloud)
        guard let number = request.payload["task"].flatMap(Int.init) else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--task is required"))
        }
        let payload = request.payload
        // `nil` leaves the milestone alone; `.some(nil)` clears it — never collapse the two.
        let milestone: Int??
        if payload["noVersion"] != nil {
            milestone = .some(nil)
        } else if let version = payload["version"], !version.isEmpty {
            milestone = .some(try milestoneNumber(forVersion: version, config: config, cloud: deps.cloud))
        } else {
            milestone = nil
        }
        guard let token = deps.tokenProvider(config) else { throw noToken(config) }
        let live = try await liveTask(number, config: config, token: token, deps: deps)

        let current = TaskItem(number: number, title: live.title, body: live.body,
                               feedbackRefs: FeedbackTaskRefParser.parse(live.body),
                               status: TaskStatus(labels: live.labels),
                               priority: TaskPriority(labels: live.labels),
                               milestoneTitle: nil, isClosed: live.state == "closed")
        let title = payload["title"].flatMap { $0.isEmpty ? nil : $0 } ?? current.title
        let prose = payload["setNotes"] != nil ? (payload["notes"] ?? "") : FeedbackTaskRefParser.prose(of: live.body)
        // A closed task reads as done, as it does in the app, so an edit can't silently reopen it.
        let status = TaskStatus(rawValue: payload["status"] ?? "") ?? current.displayStatus
        let priority = TaskPriority(rawValue: payload["priority"] ?? "") ?? current.priority
        do {
            try await deps.taskService.applyEdits(repo: config, task: current, title: title, prose: prose,
                                                  status: status, priority: priority, milestoneNumber: milestone)
        } catch TaskService.ServiceError.noToken {
            throw noToken(config)
        } catch {
            throw CLIError.remote(message: error.localizedDescription)
        }
        await deps.registry.load(productID: config.id)

        let milestoneName: String?
        switch milestone {
        case .some(.none): milestoneName = nil
        case .some(.some): milestoneName = payload["version"]
        case .none:
            milestoneName = TaskIndex.build(local: deps.local, owner: config.owner, repo: config.repo)
                .tasks.first { $0.number == number }?.milestoneTitle
        }
        let result = TaskDetail(number: number, title: title, status: status.rawValue,
                                priority: priority.rawValue, isClosed: status == .done,
                                milestone: milestoneName, notes: prose,
                                feedback: TaskIndex.linkedFeedback(current.feedbackRefs, config: config,
                                                                   local: deps.local),
                                url: FeedbackQuery.url(for: number, config: config))
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(result))
    }

    /// `RootView.deleteTask`: delete the issue on GitHub, then purge it from the cache so it
    /// doesn't reappear (the incremental fetch never reports deletions).
    static func deleteTask(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let config = try resolveConfig(request, cloud: deps.cloud)
        guard let number = request.payload["task"].flatMap(Int.init) else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--task is required"))
        }
        guard let token = deps.tokenProvider(config) else { throw noToken(config) }
        let live = try await liveTask(number, config: config, token: token, deps: deps)
        let task = TaskItem(number: number, title: live.title, body: live.body,
                            feedbackRefs: FeedbackTaskRefParser.parse(live.body),
                            status: TaskStatus(labels: live.labels), priority: TaskPriority(labels: live.labels),
                            milestoneTitle: nil, isClosed: live.state == "closed")
        do {
            try await deps.taskService.deleteTask(repo: config, task: task)
        } catch TaskService.ServiceError.noToken {
            throw noToken(config)
        } catch let error as GitHubIssueWriter.WriteError where !error.isNotFound {
            throw CLIError.remote(message: error.localizedDescription,
                                  hint: "Deleting an issue needs admin or maintain access to the repository.")
        } catch let error as GitHubIssueWriter.WriteError where error.isNotFound {
            // Already gone on GitHub — purging the stale copy below is all that's left to do.
        } catch {
            throw CLIError.remote(message: error.localizedDescription)
        }
        deps.registry.loaders[config.id]?.purgeFromCache(number: number)
        return CLIResponse(id: request.id, ok: true,
                           json: CLIOutput.encode(DeletedTask(deleted: number, title: live.title)))
    }

    struct DeletedTask: Codable, Equatable { let deleted: Int; let title: String }
    struct DeletedResponse: Codable, Equatable { let deletedResponseFor: Int; let url: String }

    // MARK: - feedback mark-read

    struct MarkReadResult: Codable, Equatable {
        let marked: [Int]
        let alreadyRead: Int
    }

    /// Opening an item in the list marks it seen (`IssueListViewModel.markSeen`); this is that,
    /// for one item, several, or every cached feedback item of the product.
    static func markRead(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let config = try resolveConfig(request, cloud: deps.cloud)
        let feedback = VersionQuery.issues(config: config, local: deps.local).feedback.map(\.number)
        let requested: [Int]
        if request.payload["all"] != nil {
            requested = feedback
        } else {
            requested = numbers(request.payload["feedback"])
            let unknown = requested.filter { !feedback.contains($0) }
            guard unknown.isEmpty else {
                throw CLIError.notFound(code: "feedback_not_found",
                                        message: "Not cached feedback in \(config.owner)/\(config.repo): "
                                               + unknown.map { "#\($0)" }.joined(separator: ", "))
            }
        }
        let seen = app.seen.seenNumbers(owner: config.owner, repo: config.repo)
        let toMark = requested.filter { !seen.contains($0) }.sorted()
        app.seen.markSeenBulk(owner: config.owner, repo: config.repo, issueNumbers: toMark)
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(
            MarkReadResult(marked: toMark, alreadyRead: requested.count - toMark.count)))
    }

    // MARK: - feedback triage

    struct TriageResult: Codable, Equatable {
        let feedback: Int
        let action: String
        let task: Int?
    }

    /// The suggestion chip's Accept / Dismiss on a feedback card.
    static func triage(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let config = try resolveConfig(request, cloud: deps.cloud)
        guard let coordinator = app.triage else {
            throw CLIError.remote(message: "Triage is unavailable in this build.")
        }
        guard let number = numbers(request.payload["feedback"]).first else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--feedback is required"))
        }
        guard let record = coordinator.pendingSuggestion(owner: config.owner, repo: config.repo, number: number) else {
            throw CLIError.notFound(code: "no_triage_suggestion",
                                    message: "Feedback #\(number) has no pending triage suggestion.",
                                    hint: "Only items whose `triage.state` is `pending` can be accepted or dismissed.")
        }
        if request.payload["action"] == "dismiss" {
            coordinator.dismiss(record: record)
            return CLIResponse(id: request.id, ok: true,
                               json: CLIOutput.encode(TriageResult(feedback: number, action: "dismissed", task: nil)))
        }
        do {
            try await coordinator.accept(record: record, repo: config,
                                         issues: VersionQuery.allIssues(config: config, local: deps.local))
        } catch {
            throw CLIError.remote(message: "Couldn't accept the suggestion for #\(number): \(error.localizedDescription)")
        }
        await deps.registry.load(productID: config.id)
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(TriageResult(
            feedback: number, action: "accepted",
            task: record.createdTaskNumber ?? record.suggestedTaskNumber)))
    }

    // MARK: - respond --delete

    /// The App Store response panel's Delete.
    static func deleteAppStoreResponse(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let config = try resolveConfig(request, cloud: deps.cloud)
        guard let number = numbers(request.payload["feedback"]).first else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--feedback is required"))
        }
        let issue = try FeedbackQuery.rawIssue(number: number, config: config, local: deps.local)
        guard let reply = deps.reply else {
            throw CLIError.remote(message: "App Store responses are unavailable in this build.")
        }
        let controller = try await appStoreController(for: issue, reply: reply)
        guard controller.mode == .hasResponse else {
            throw CLIError.notFound(code: "no_app_store_response",
                                    message: "Review #\(number) has no developer response to delete.")
        }
        await controller.delete()
        if let error = controller.lastError { throw appStoreError(error) }
        guard !controller.discoveredReadOnly else {
            throw CLIError.auth(message: "This App Store Connect key is read-only.",
                                hint: "Use a key with App Manager access to delete responses.")
        }
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(
            DeletedResponse(deletedResponseFor: number, url: FeedbackQuery.url(for: number, config: config))))
    }

    // MARK: - templates

    static func templateStore(_ deps: Dependencies) throws -> ReplyTemplateStore {
        guard let store = deps.reply?.templateStore else {
            throw CLIError.remote(message: "Reply templates are unavailable in this build.")
        }
        return store
    }

    /// `ReplyTemplateEditorView`'s Save for a new template.
    static func createTemplate(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let config = try resolveConfig(request, cloud: deps.cloud)
        let store = try templateStore(deps)
        let title = (request.payload["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (request.payload["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "A template needs a title and a body."))
        }
        let existing = store.templates(owner: config.owner, repo: config.repo)
        if existing.contains(where: { $0.title.compare(title, options: .caseInsensitive) == .orderedSame }) {
            throw CLIError.usage(CLIUsageError(code: "template_exists",
                                               message: "A template titled '\(title)' already exists.",
                                               hint: "Use `templates update --template \"\(title)\"`."))
        }
        let created = store.create(owner: config.owner, repo: config.repo, title: title, body: body)
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(TemplateQuery.dto(created)))
    }

    /// `ReplyTemplateEditorView`'s Save for an existing template.
    static func updateTemplate(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let config = try resolveConfig(request, cloud: deps.cloud)
        let store = try templateStore(deps)
        let template = try TemplateQuery.find(request.payload["template"] ?? "",
                                              in: store.templates(owner: config.owner, repo: config.repo))
        let title = (request.payload["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (request.payload["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(template, title: title.isEmpty ? template.title : title,
                     body: body.isEmpty ? template.body : body)
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(TemplateQuery.dto(template)))
    }

    static func deleteTemplate(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let config = try resolveConfig(request, cloud: deps.cloud)
        let store = try templateStore(deps)
        let template = try TemplateQuery.find(request.payload["template"] ?? "",
                                              in: store.templates(owner: config.owner, repo: config.repo))
        let title = template.title
        store.delete(template)
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(["deleted": title]))
    }
}

#endif
