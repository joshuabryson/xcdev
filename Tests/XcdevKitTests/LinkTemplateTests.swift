import Foundation
import Testing
@testable import XcdevKit

@Suite struct LinkTemplateTests {
    func problem(_ text: String) -> String? {
        do {
            _ = try LinkTemplate(text)
            return nil
        } catch {
            return (error as? LinkTemplate.Problem)?.message
        }
    }

    @Test func placeholdersAndLiteralBraces() throws {
        let template = try LinkTemplate("a{x}b{{c}}{y}")
        #expect(template.parts == [.text("a"), .placeholder("x"), .text("b{c}"), .placeholder("y")])
        #expect(template.names == ["x", "y"])
        #expect(template.filled { $0.uppercased() } == "aXb{c}Y")
        #expect(try LinkTemplate("").parts.isEmpty)
        #expect(try LinkTemplate("plain").names.isEmpty)
    }

    /// A value is put in once and never read again, so a value that looks like a placeholder stays as it is.
    @Test func aValueThatHoldsBracesIsNotExpandedAgain() throws {
        #expect(try LinkTemplate("{a}-{b}").filled { $0 == "a" ? "{b}" : "B" } == "{b}-B")
    }

    @Test func malformedBracesSayWhatIsWrong() {
        #expect(problem("a{b") == "has a '{' that is never closed (write '{{' for a literal brace)")
        #expect(problem("a{b{c}") == "has a '{' that is never closed (write '{{' for a literal brace)")
        #expect(problem("a}b") == "has a '}' that closes nothing (write '}}' for a literal brace)")
        #expect(problem("a{}b") == "has an empty placeholder '{}'")
        #expect(problem("{{}}") == nil)
        #expect(problem("{{{a}}}") == nil)
    }

    @Test func tripleBracesAreALiteralBraceAroundAPlaceholder() throws {
        #expect(try LinkTemplate("{{{a}}}").filled { _ in "1" } == "{1}")
    }

    @Test func aURLIsSplitIntoItsQueryItemsBeforeAnythingIsFilledIn() throws {
        let url = try URLTemplate("{base}/item?id={id}&tab={tab}#top{anchor}")
        #expect(url.head.names == ["base"])
        #expect(url.items?.map(\.names) == [["id"], ["tab"]])
        #expect(url.fragment?.names == ["anchor"])
        #expect(url.names == ["base", "id", "tab", "anchor"])
        #expect(try URLTemplate("myapp://x").items == nil)
        #expect(try URLTemplate("myapp://x#a?b").items == nil)             // a `?` after the `#` is part of the fragment
    }

    @Test func anItemsWholeValue() throws {
        #expect(try LinkTemplate("tab={tab}").wholeValueName == "tab")
        #expect(try LinkTemplate("{key}={tab}").wholeValueName == "tab")
        #expect(try LinkTemplate("tab=x{tab}").wholeValueName == nil)
        #expect(try LinkTemplate("tab={tab}x").wholeValueName == nil)
        #expect(try LinkTemplate("a=b={tab}").wholeValueName == nil)
        #expect(try LinkTemplate("{tab}").wholeValueName == nil)
        #expect(try LinkTemplate("tab").wholeValueName == nil)
    }

    @Test func anOptionalItemIsDroppedWithItsQuestionMark() throws {
        let url = try URLTemplate("myapp://item?id={id}&tab={tab}")
        #expect(url.filled { ["id": "7", "tab": "notes"][$0] } == "myapp://item?id=7&tab=notes")
        #expect(url.filled { ["id": "7"][$0] } == "myapp://item?id=7")
        #expect(url.filled { ["id": "7", "tab": ""][$0] } == "myapp://item?id=7&tab=")      // an empty value is a value
        let only = try URLTemplate("myapp://item?tab={tab}#end")
        #expect(only.filled { _ in nil } == "myapp://item#end")
        #expect(only.filled { _ in "a" } == "myapp://item?tab=a#end")
    }

    /// The items are found in the template, so a value with `?`, `&`, or `#` in it cannot add or remove one.
    @Test func aValueCannotChangeWhichItemsExist() throws {
        let url = try URLTemplate("{base}/item?id={id}&tab={tab}")
        let values = ["base": "myapp://host/x?y=1&z=2", "id": "a&b#c"]
        #expect(url.filled { values[$0] } == "myapp://host/x?y=1&z=2/item?id=a&b#c")
    }

    @Test func misplacedOptionalParametersAreNamed() throws {
        let optional: Set = ["tab", "page"]
        #expect(try URLTemplate("myapp://item?id={id}&tab={tab}").misplaced(optional: optional).isEmpty)
        #expect(try URLTemplate("myapp://{tab}/item").misplaced(optional: optional) == ["tab"])
        #expect(try URLTemplate("myapp://item?x={tab}-{page}").misplaced(optional: optional) == ["tab", "page"])
        #expect(try URLTemplate("myapp://item?tab=a{tab}").misplaced(optional: optional) == ["tab"])
        #expect(try URLTemplate("myapp://item?{tab}={tab}").misplaced(optional: optional) == ["tab"])
        #expect(try URLTemplate("myapp://item#{page}").misplaced(optional: optional) == ["page"])
    }

    @Test func encodingKeepsOnlyUnreservedCharacters() {
        #expect(LinkEncoding.encode("AZaz09-._~") == "AZaz09-._~")
        #expect(LinkEncoding.encode("a b&c/d%e=f?g#h") == "a%20b%26c%2Fd%25e%3Df%3Fg%23h")
        #expect(LinkEncoding.encode("naïve é") == "na%C3%AFve%20%C3%A9")
        #expect(LinkEncoding.encode("日本") == "%E6%97%A5%E6%9C%AC")
        #expect(LinkEncoding.encode("") == "")
    }

    @Test func schemes() {
        #expect(LinkScheme.of("myapp://x") == "myapp")
        #expect(LinkScheme.of("MyApp:x") == "MyApp")                        // as written: the approval needs the same spelling
        #expect(LinkScheme.of("https://example.com/a:b") == "https")
        #expect(LinkScheme.of("com.example+x-1:thing") == "com.example+x-1")
        #expect(LinkScheme.of("no scheme") == nil)
        #expect(LinkScheme.of("1abc://x") == nil)
        #expect(LinkScheme.of("://x") == nil)
        #expect(LinkScheme.of("my app://x") == nil)
        #expect(LinkScheme.of("{id}://x") == nil)
        #expect(LinkScheme.isWeb("HTTPS") && LinkScheme.isWeb("http") && !LinkScheme.isWeb("myapp"))
    }
}
