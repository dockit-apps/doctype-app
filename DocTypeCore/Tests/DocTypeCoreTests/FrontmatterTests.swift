// Tests for splitting frontmatter and reading tags.

import Testing
@testable import DocTypeCore

struct FrontmatterTests {
    @Test func noFrontmatter() {
        let (frontmatter, body) = Frontmatter.split("# Hello\nworld")
        #expect(frontmatter == nil)
        #expect(body == "# Hello\nworld")
    }

    @Test func emptyBlock() {
        let (frontmatter, body) = Frontmatter.split("---\n---\nBody")
        #expect(frontmatter?.raw == "---\n---\n")
        #expect(frontmatter?.tags == [])
        #expect(body == "Body")
    }

    @Test func flowList() {
        let (frontmatter, body) = Frontmatter.split("---\ntitle: x\ntags: [algo, \"exam prep\", 'week 3']\n---\nBody")
        #expect(frontmatter?.tags == ["algo", "exam prep", "week 3"])
        #expect(body == "Body")
    }

    @Test func blockList() {
        let text = "---\ntags:\n  - algo\n  - graphs\nauthor: me\n---\n"
        #expect(Frontmatter.split(text).frontmatter?.tags == ["algo", "graphs"])
    }

    @Test func commaSeparatedScalar() {
        #expect(Frontmatter.split("---\ntags: a, b\n---\n").frontmatter?.tags == ["a", "b"])
    }

    @Test func crlfLineEndings() {
        let (frontmatter, body) = Frontmatter.split("---\r\ntags: [a]\r\n---\r\nBody\r\n")
        #expect(frontmatter?.tags == ["a"])
        #expect(frontmatter?.raw == "---\r\ntags: [a]\r\n---\r\n")
        #expect(body == "Body\r\n")
    }

    @Test func unclosedBlockIsBody() {
        let text = "---\ntags: [a]\nno closing line"
        let (frontmatter, body) = Frontmatter.split(text)
        #expect(frontmatter == nil)
        #expect(body[...] == text[...])
    }

    @Test func horizontalRuleLaterIsNotFrontmatter() {
        #expect(Frontmatter.split("Intro\n---\nmore\n---\n").frontmatter == nil)
    }

    @Test func dotsCloseTheBlock() {
        #expect(Frontmatter.split("---\ntags: [a]\n...\nBody").frontmatter?.tags == ["a"])
    }

    @Test func blockAtEndOfFileWithoutNewline() {
        let (frontmatter, body) = Frontmatter.split("---\ntags: [a]\n---")
        #expect(frontmatter?.tags == ["a"])
        #expect(body.isEmpty)
    }
}
