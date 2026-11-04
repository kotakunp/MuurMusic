import XCTest
@testable import MuurCore

/// AWS Signature Version 4 test suite vectors (sigv4-test-suite, get-object / get-key-value).
final class S3SignerTests: XCTestCase {

    private let accessKey = "AKIAIOSFODNN7EXAMPLE"
    private let secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    /// 2013-05-24T00:00:00Z, the fixed date of the AWS examples.
    private let referenceDate = Date(timeIntervalSince1970: 1369353600)

    private var signer: S3Signer {
        S3Signer(accessKey: accessKey, secretKey: secretKey, region: "us-east-1")
    }

    func testTimestampsMatchAWSFormat() {
        let (amzDate, dateStamp) = S3Signer.timestamps(for: referenceDate)
        XCTAssertEqual(amzDate, "20130524T000000Z")
        XCTAssertEqual(dateStamp, "20130524")
    }

    func testCanonicalURIEscapesPerSegment() {
        XCTAssertEqual(S3Signer.canonicalURI("/test.txt"), "/test.txt")
        XCTAssertEqual(S3Signer.canonicalURI("/a b/c+ d.txt"), "/a%20b/c%2B%20d.txt")
        XCTAssertEqual(S3Signer.canonicalURI(""), "/")
    }

    /// AWS example: GET https://examplebucket.s3.amazonaws.com/test.txt with Range: bytes=0-9.
    func testSignedRequestMatchesAWSVector() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        var request = URLRequest(url: url)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        signer.sign(&request, date: referenceDate)

        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authorization.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "))
        XCTAssertTrue(authorization.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(authorization.contains(
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.emptyPayloadHash)
    }

    /// AWS example: presigned GET for the same object with Expires 86400.
    func testPresignedURLMatchesAWSVector() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let presigned = signer.presignedURL(url: url, expires: 86400, date: referenceDate)
        let text = presigned.absoluteString
        XCTAssertTrue(text.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        XCTAssertTrue(text.contains("X-Amz-Date=20130524T000000Z"))
        XCTAssertTrue(text.contains("X-Amz-Expires=86400"))
        XCTAssertTrue(text.contains("X-Amz-SignedHeaders=host"))
        XCTAssertTrue(text.contains("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))
    }

    func testCredentialScopeIncludesService() {
        XCTAssertEqual(signer.credentialScope(dateStamp: "20130524"), "20130524/us-east-1/s3/aws4_request")
        let glacier = S3Signer(accessKey: accessKey, secretKey: secretKey, region: "us-west-2", service: "glacier")
        XCTAssertEqual(glacier.credentialScope(dateStamp: "20130524"), "20130524/us-west-2/glacier/aws4_request")
    }
}
