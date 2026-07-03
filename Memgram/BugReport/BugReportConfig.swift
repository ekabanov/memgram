// Bug-report submission credentials.
//
// This tracked copy ships with an empty token — bug reporting is simply
// disabled in builds without one (the Help tab explains this instead of
// failing). To enable it locally, paste a fine-grained GitHub PAT with
// Issues: Read and write access to the repo below, then protect your copy
// from accidental commits with:
//
//   git update-index --skip-worktree Memgram/BugReport/BugReportConfig.swift
//
// NEVER commit a real token.
enum BugReportConfig {
    static let githubToken  = ""
    static let repoOwner    = "ekabanov"
    static let repoName     = "memgram-bugs"
}
