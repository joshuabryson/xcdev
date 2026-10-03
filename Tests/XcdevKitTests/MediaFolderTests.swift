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

    @Test func theFolderIsIgnoredOnlyInsideTheMainCheckout() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = try checkout("main", head: "ref: refs/heads/main\n")
        let inside = MediaFolder(directory: main + "/.xcdev-media/main/main", projectRoot: main)
        #expect(try inside.ensureIgnored() == ".xcdev-media/")
        #expect(try inside.ensureIgnored() == nil)
        #expect(try String(contentsOfFile: main + "/.gitignore", encoding: .utf8)
                == "# xcdev: screenshots and recordings\n.xcdev-media/\n")
        #expect(try MediaFolder(directory: "/elsewhere/m", projectRoot: main).ensureIgnored() == nil)
    }

    @Test func theMediaRootIsThePartBeforeTheFirstPlaceholder() {
        #expect(MediaFolder.root(template: ".xcdev-media/{worktree}/{branch}", projectRoot: "/p", home: "/h") == "/p/.xcdev-media")
        #expect(MediaFolder.root(template: "~/C/{project}", projectRoot: "/p", home: "/h") == "/h/C")
        #expect(MediaFolder.root(template: "/abs/shots", projectRoot: "/p", home: "/h") == "/abs/shots")
        #expect(MediaFolder.root(template: "{branch}/shots", projectRoot: "/p", home: "/h") == nil)
    }
}
