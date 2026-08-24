//
//  SharePlatformTests.swift
//  RecipeKitTests
//
//  Covers URL-host classification used to show a source icon on the processing
//  card at queue time. Parity target: the backend's urls.py buckets.
//

import XCTest
@testable import RecipeKit

final class SharePlatformTests: XCTestCase {

    func testInstagramReel() {
        XCTAssertEqual(SharePlatform(url: "https://www.instagram.com/reel/ABC123/"), .instagram)
    }

    func testInstagramPostAndShortHost() {
        XCTAssertEqual(SharePlatform(url: "https://instagram.com/p/XYZ/"), .instagram)
        XCTAssertEqual(SharePlatform(url: "https://instagr.am/reel/XYZ/"), .instagram)
    }

    func testTikTokFullAndShortlinks() {
        XCTAssertEqual(SharePlatform(url: "https://www.tiktok.com/@chef/video/7300000000000000000"), .tiktok)
        XCTAssertEqual(SharePlatform(url: "https://vm.tiktok.com/ZMabcdef/"), .tiktok)
        XCTAssertEqual(SharePlatform(url: "https://vt.tiktok.com/ZSabcdef/"), .tiktok)
    }

    func testGenericBlogIsWeb() {
        XCTAssertEqual(SharePlatform(url: "https://smittenkitchen.com/2020/01/best-cookies/"), .web)
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertEqual(SharePlatform(url: "https://WWW.Instagram.COM/reel/A/"), .instagram)
        XCTAssertEqual(SharePlatform(url: "https://TikTok.com/@x/video/1"), .tiktok)
    }

    func testUnparseableOrEmptyFallsBackToWeb() {
        XCTAssertEqual(SharePlatform(url: ""), .web)
        XCTAssertEqual(SharePlatform(url: "not a url"), .web)
    }

    func testLeadingWhitespaceIsTrimmed() {
        XCTAssertEqual(SharePlatform(url: "  https://www.tiktok.com/@x/video/1  "), .tiktok)
    }

    func testDomainInPathDoesNotMisclassify() {
        // "tiktok.com" only in the path/query, not the host → still web.
        XCTAssertEqual(SharePlatform(url: "https://example.com/redirect?to=tiktok.com"), .web)
    }

    func testPendingJobExposesPlatform() {
        let job = PendingJob(jobId: "j1", url: "https://www.tiktok.com/@x/video/1")
        XCTAssertEqual(job.platform, .tiktok)
    }
}
