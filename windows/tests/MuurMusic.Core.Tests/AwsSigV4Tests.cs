using MuurMusic.Core.Sources;

namespace MuurMusic.Core.Tests;

/// <summary>AWS Signature Version 4 test vectors from the AWS documentation (get-vanilla suite).</summary>
public class AwsSigV4Tests
{
    private const string AccessKey = "AKIDEXAMPLE";
    private const string SecretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    private static readonly DateTimeOffset Timestamp = new(2015, 8, 30, 12, 36, 0, TimeSpan.Zero);

    [Fact]
    public void GetVanilla_Matches_Aws_Reference_Signature()
    {
        var headers = new Dictionary<string, string>
        {
            ["host"] = "example.amazonaws.com",
            ["x-amz-date"] = "20150830T123600Z"
        };
        var (authorization, signature) = AwsSigV4.Sign("GET", "/", "", headers,
            AwsSigV4.Sha256Hex(""), AccessKey, SecretKey, "us-east-1", "service", Timestamp);

        Assert.Equal("5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", signature);
        Assert.Equal("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
                     "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", authorization);
    }

    [Fact]
    public void SigningKey_And_Scope_Are_Derived_Per_Spec()
    {
        var key = AwsSigV4.SigningKey(SecretKey, "20150830", "us-east-1", "service");
        Assert.Equal("938127b5336810ddb6a5d6af445fcac9e371f9ed418ed386b022aed82901be75", AwsSigV4.Hex(key));
        Assert.Equal("20150830/us-east-1/service/aws4_request", AwsSigV4.Scope("20150830", "us-east-1", "service"));
    }

    [Fact]
    public void CanonicalQuery_Sorts_And_Encodes()
    {
        var q = AwsSigV4.CanonicalQuery(new[]
        {
            new KeyValuePair<string, string>("b", "two words"),
            new KeyValuePair<string, string>("a", "x/y"),
            new KeyValuePair<string, string>("a", "m"),
        });
        Assert.Equal("a=m&a=x%2Fy&b=two%20words", q);
    }

    [Fact]
    public void Encode_Follows_Rfc3986()
    {
        Assert.Equal("a%2Fb%20c%2A", AwsSigV4.Encode("a/b c*"));
        Assert.Equal("a/b%20c", AwsSigV4.Encode("a/b c", keepSlash: true));
        Assert.Equal("%E2%9C%93", AwsSigV4.Encode("✓"));
    }
}
