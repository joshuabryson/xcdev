import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct MediaFolderTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd media \(UUID().uuidString)").path

    /// A checkout at `base/name` whose .git is a folder (main) or a file pointing elsewhere (linked worktree).
    func checkout(_ name: String, head: String, linked: Bool = false) throws -> String {
        let root = base + "/" + name
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        if linked {
            let gitdir = base + "/main/.git/worktrees/" + name
            try fm.createDirectory(atPath: gitdir, withIntermediateDirectories: true)
            try head.write(toFile: gitdir + "/HEAD", atomically: true, encoding: .utf8)
            try "gitdir: \(gitdir)\n".write(toFile: root + "/.git", atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
            try head.write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func readsTheBranchOfAMainAndALinkedCheckout() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("main", head: "ref: refs/heads/main\n")
        let linked = try checkout("login", head: "ref: refs/heads/feature/login\n", linked: true)
        #expect(GitHead.read(worktreeRoot: main) == .branch("main"))
        #expect(GitHead.read(worktreeRoot: linked) == .branch("feature/login"))
        #expect(GitHead.read(worktreeRoot: base + "/nowhere") == nil)
    }

    @Test func aRelativeGitdirIsResolvedFromTheCheckout() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let root = base + "/rel"
        try FileManager.default.createDirectory(atPath: base + "/gitdirs/rel", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "ref: refs/heads/x\n".write(toFile: base + "/gitdirs/rel/HEAD", atomically: true, encoding: .utf8)
        try "gitdir: ../gitdirs/rel\n".write(toFile: root + "/.git", atomically: true, encoding: .utf8)
        #expect(GitHead.read(worktreeRoot: root) == .branch("x"))
    }

    @Test func expandsEveryPlaceholderAgainstTheMainCheckout() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("My App", head: "ref: refs/heads/main\n")
        let wt = try checkout("login", head: "ref: refs/heads/feature/login\n", linked: true)
        let folder = MediaFolder.resolve(template: "media/{project}/{worktree}/{branch}/{device}", projectRoot: main,
                                         worktreeRoot: wt, worktreeName: "login", device: "iphone", home: "/Users/dev")
        #expect(folder.directory == main + "/media/My-App/login/feature/login/iphone")
        #expect(MediaFolder.resolve(template: "~/Captures/{worktree}", projectRoot: main, worktreeRoot: wt,
                                    worktreeName: "login", device: nil, home: "/Users/dev").directory == "/Users/dev/Captures/login")
        #expect(MediaFolder.resolve(template: "/abs/{device}", projectRoot: main, worktreeRoot: wt,
                                    worktreeName: "login", device: nil, home: "/h").directory == "/abs/nodevice")
    }

    @Test func branchNamesBecomeSafeNestedFolders() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("main", head: "ref: refs/heads/main\n")
        let wt = try checkout("odd", head: "ref: refs/heads/../x//my branch/./é\n", linked: true)
        let folder = MediaFolder.resolve(template: ".m/{branch}", projectRoot: main, worktreeRoot: wt,
                                         worktreeName: "odd", device: nil, home: "/h")
        #expect(folder.directory == main + "/.m/x/my-branch/é")
        #expect(folder.directory.hasPrefix(main + "/.m/"))
    }

    @Test func aDetachedHeadUsesItsCommit() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("main", head: "0123456789abcdef0123456789abcdef01234567\n")
        #expect(GitHead.read(worktreeRoot: main) == .detached(commit: "0123456789abcdef0123456789abcdef01234567"))
        let folder = MediaFolder.resolve(template: ".m/{branch}", projectRoot: main, worktreeRoot: main,
                                         worktreeName: "main", device: nil, home: "/h")
        #expect(folder.directory == main + "/.m/detached-0123456789ab")
        let none = MediaFolder.resolve(template: ".m/{branch}", projectRoot: base + "/nogit", worktreeRoot: base + "/nogit",
                                       worktreeName: "main", device: nil, home: "/h")
        #expect(none.directory == base + "/nogit/.m/nobranch")
    }

    @Test func aHeadFileThatIsNeitherARefNorAValidCommitIsUnreadable() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("main", head: "../../../../etc\n")
        #expect(GitHead.read(worktreeRoot: main) == nil)
        let folder = MediaFolder.resolve(template: ".m/{branch}", projectRoot: main, worktreeRoot: main,
                                         worktreeName: "main", device: nil, home: "/h")
        #expect(folder.directory == main + "/.m/nobranch")
        #expect(folder.directory.hasPrefix(main + "/.m/"))
    }

    @Test func newFilesAreTimestampedPerDeviceAndNeverCollide() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = MediaFolder(directory: base + "/m", projectRoot: base)
        let now = Date(timeIntervalSince1970: 1_791_085_501)
        let first = folder.newFile(device: "iphone", kind: "screenshot", ext: "png", now: now)
        FileManager.default.createFile(atPath: first, contents: Data())
        let second = folder.newFile(device: "iphone", kind: "screenshot", ext: "png", now: now)
        #expect(first.hasPrefix(base + "/m/") && first.hasSuffix("-iphone-screenshot.png"))
        #expect(second == first.replacingOccurrences(of: ".png", with: "-2.png"))
    }

    /// The entry `ensureIgnored` adds for `template`, in a fresh main checkout.
    func ignored(_ template: String, home: String = "/Users/dev") throws -> (entry: String?, gitignore: String?) {
        let main = try checkout("main", head: "ref: refs/heads/main\n")
        let folder = MediaFolder.resolve(template: template, projectRoot: main, worktreeRoot: main, worktreeName: "main",
                                         device: "iphone", home: home)
        let entry = try folder.ensureIgnored()
        return (entry, try? String(contentsOfFile: main + "/.gitignore", encoding: .utf8))
    }

    @Test func theDefaultFolderIsIgnoredOnceInsideTheMainCheckout() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("main", head: "ref: refs/heads/main\n")
        let folder = MediaFolder.resolve(template: XcdevConfig.defaultMediaDir, projectRoot: main, worktreeRoot: main,
                                         worktreeName: "main", device: nil, home: "/h")
        #expect(try folder.ensureIgnored() == ".xcdev-media/")
        #expect(try folder.ensureIgnored() == nil)
        #expect(try String(contentsOfFile: main + "/.gitignore", encoding: .utf8)
                == "# xcdev: screenshots and recordings\n.xcdev-media/\n")
    }

    @Test func aTemplatesFixedPrefixIsIgnoredNotItsFirstFolder() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(try ignored("docs/screens/{branch}").entry == "docs/screens/")
        try? FileManager.default.removeItem(atPath: base)
        #expect(try ignored("shots/{device}").entry == "shots/")
        try? FileManager.default.removeItem(atPath: base)
        #expect(try ignored("fixed/all/the/way").entry == "fixed/all/the/way/")
    }

    @Test func aTemplateStartingWithAPlaceholderIgnoresItsFirstExpandedFolder() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(try ignored("{branch}/shots").entry == "main/")
    }

    @Test func aFolderOutsideTheMainCheckoutOrTheCheckoutItselfAddsNothing() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("main", head: "ref: refs/heads/main\n")
        #expect(try MediaFolder(directory: "/elsewhere/m", projectRoot: main).ensureIgnored() == nil)
        #expect(try ignored("~/Captures/{worktree}").entry == nil)
        try? FileManager.default.removeItem(atPath: base)
        #expect(try ignored("/abs/shots").entry == nil)
        try? FileManager.default.removeItem(atPath: base)
        #expect(try ignored("../media/{device}").entry == nil)
        try? FileManager.default.removeItem(atPath: base)
        let atRoot = try ignored("./{device}")
        #expect(atRoot.entry == "iphone/")      // no fixed prefix beyond the checkout: first expanded folder
        #expect(try ignored("~").entry == nil)
    }

    @Test func theMediaRootIsThePartBeforeTheFirstPlaceholder() {
        #expect(MediaFolder.root(template: ".xcdev-media/{worktree}/{branch}", projectRoot: "/p", home: "/h") == "/p/.xcdev-media")
        #expect(MediaFolder.root(template: "~/C/{project}", projectRoot: "/p", home: "/h") == "/h/C")
        #expect(MediaFolder.root(template: "/abs/shots", projectRoot: "/p", home: "/h") == "/abs/shots")
        #expect(MediaFolder.root(template: "{branch}/shots", projectRoot: "/p", home: "/h") == nil)
    }
}
