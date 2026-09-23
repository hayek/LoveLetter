#if os(macOS)
import Foundation
import SwiftData

/// Saved reply templates, read the way `ReplyTemplateStore.templates(owner:repo:)` lists them.
enum TemplateQuery {

    /// One product's templates, newest-edited first.
    static func templates(config: ProductConfig, cloud: ModelContext) -> [ReplyTemplate] {
        let owner = config.owner, repo = config.repo
        return ((try? cloud.fetch(FetchDescriptor<ReplyTemplate>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Titles match case-insensitively, as `respond --template` does.
    static func find(_ title: String, in templates: [ReplyTemplate]) throws -> ReplyTemplate {
        guard let match = templates.first(where: {
            $0.title.compare(title, options: .caseInsensitive) == .orderedSame
        }) else {
            throw CLIError.notFound(code: "template_not_found",
                                    message: "No reply template titled '\(title)'.",
                                    candidates: templates.map(\.title))
        }
        return match
    }

    static func dto(_ template: ReplyTemplate) -> TemplateDTO {
        TemplateDTO(title: template.title, body: template.body, updatedAt: template.updatedAt)
    }
}

/// The GitHub and mail accounts connected in Love Letter.
enum AccountsQuery {
    /// Addresses are shown in full: these are the developer's own accounts, not reporters'.
    static func run(cloud: ModelContext) -> AccountsDTO {
        let github = ((try? cloud.fetch(FetchDescriptor<GitHubAccount>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { !$0.login.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { AccountsDTO.GitHub(login: $0.login) }
        let products = ProductResolver.products(cloud: cloud)
        let mail = ((try? cloud.fetch(FetchDescriptor<MailAccount>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .map { account in
                let address = account.imapUsername.isEmpty ? account.smtpUsername : account.imapUsername
                return AccountsDTO.Mail(
                    address: address,
                    service: account.preset.rawValue,
                    isDefaultSender: account.isDefaultSender,
                    feedbackInboxFor: account.feedbackProductID.flatMap { id in
                        products.first { $0.id == id }?.displayName
                    })
            }
        return AccountsDTO(github: github, mail: mail)
    }
}
#endif
