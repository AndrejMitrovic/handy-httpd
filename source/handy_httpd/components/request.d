/** 
 * Contains HTTP request components.
 */
module handy_httpd.components.request;

import handy_httpd.server: HttpServer;
import handy_httpd.components.response : HttpResponse;
import std.range : InputRange, isOutputRange, Appender, appender;
import std.exception;
import slf4d;

/** 
 * The data which the server provides to HttpRequestHandlers so that they can
 * formulate a response.
 */
struct HttpRequest {
    /** 
     * The HTTP method verb, such as GET, POST, PUT, etc. This is internally
     * defined as a bit-shifted 1, for efficient matching logic. See the
     * `Method` enum in this module for more information.
     */
    public const Method method = Method.GET;

    /** 
     * The url of the request, excluding query parameters.
     */
    public const string url = "";

    /** 
     * The request version.
     */
    public const int ver = 1;

    /** 
     * An associative array containing all request headers.
     */
    public const string[string] headers;

    /** 
     * An associative array containing all request params, if any were given.
     */
    public const string[string] params;

    /** 
     * An associative array containing any path parameters obtained from the
     * request url. These are only populated in cases where it is possible to
     * parse path parameters, such as with a PathDelegatingHandler.
     */
    public string[string] pathParams;

    /** 
     * The input range that can be used to read this request's body in chunks
     * of `ubyte[]`. It can be null, indicating that this request does not have
     * a body. In practice, this will usually be a `SocketInputRange`.
     */
    public InputRange!(ubyte[]) inputRange;

    /** 
     * Gets a URL parameter as the specified type, or returns the default value
     * if the parameter with the given name doesn't exist or is of an invalid
     * format.
     * Params:
     *   name = The name of the URL parameter.
     *   defaultValue = The default value to return if the URL parameter
     *                  doesn't exist.
     * Returns: The value of the URL parameter.
     */
    public T getParamAs(T)(string name, T defaultValue = T.init) {
        import std.conv : to, ConvException;
        if (name !in params) return defaultValue;
        try {
            return params[name].to!T;
        } catch (ConvException e) {
            return defaultValue;
        }
    }

    unittest {
        HttpRequest req = HttpRequest(
            Method.GET,
            "/api",
            1,
            string[string].init,
            [
                "a": "123",
                "b": "c",
                "c": "true"
            ],
            string[string].init
        );
        assert(req.getParamAs!int("a") == 123);
        assert(req.getParamAs!char("b") == 'c');
        assert(req.getParamAs!bool("c") == true);
        assert(req.getParamAs!int("d") == 0);
    }

    /** 
     * Gets a path parameter as the specified type, or returns the default
     * value if the path parameter with the given name doesn't exist or is
     * of an invalid format.
     * Params:
     *   name = The name of the path parameter.
     *   defaultValue = The default value to return if the path parameter
     *                  doesn't exist.
     * Returns: The value of the path parameter.
     */
    public T getPathParamAs(T)(string name, T defaultValue = T.init) const {
        import std.conv : to, ConvException;
        if (name !in pathParams) return defaultValue;
        try {
            return pathParams[name].to!T;
        } catch (ConvException e) {
            return defaultValue;
        }
    }

    unittest {
        HttpRequest req = HttpRequest();
        req.pathParams = [
            "a": "123",
            "b": "c",
            "c": "true"
        ];
        assert(req.getPathParamAs!int("a") == 123);
        assert(req.getPathParamAs!char("b") == 'c');
        assert(req.getPathParamAs!bool("c") == true);
        assert(req.getPathParamAs!int("d") == 0);
    }

    /** 
     * Reads the entirety of the request body, and passes it in chunks to the
     * given output range.
     * 
     * Throws a `SocketException` if an unrecoverable error occurs and the
     * reading cannot continue (such as a socket error or closed connection).
     *
     * Throws an exception if the connection is closed before the expected
     * data can be read (if a Content-Length header is given).
     *
     * Params:
     *   outputRange = An output range that accepts chunks of `ubyte[]`.
     *   allowInfiniteRead = Whether to allow the function to read potentially
     *                       infinitely if no Content-Length header is provided.
     * Returns: The number of bytes that were read.
     */
    public ulong readBody(R)(R outputRange, bool allowInfiniteRead = false) if (isOutputRange!(R, ubyte[])) {
        const string* contentLengthStrPtr = "Content-Length" in headers;
        // If we're not allowed to read infinitely, and no content-length is given, don't attempt to read.
        if (!allowInfiniteRead && contentLengthStrPtr is null) {
            return 0;
        }
        long contentLength = -1;
        if (contentLengthStrPtr !is null) {
            import std.conv : to, ConvException;
            try {
                contentLength = (*contentLengthStrPtr).to!long;
            } catch (ConvException e) {
                // Invalid formatting for content-length header.
                // If we don't allow infinite reading, quit 0.
                if (!allowInfiniteRead) {
                    return 0;
                }
            }
        }
        return this.readBody!(R)(outputRange, contentLength);
    }

    unittest {
        import std.conv;
        import std.range;
        import handy_httpd.util.builders;

        // Test case 1: Simply reading a string.
        string body1 = "Hello world!";
        HttpRequest r1 = new HttpRequestBuilder().withBody(body1).build();
        auto app1 = appender!(ubyte[][]);
        ulong bytesRead1 = r1.readBody(app1);
        assert(bytesRead1 == body1.length);
        assert(app1[] == [cast(ubyte[]) body1]);

        // Test case 2: Missing Content-Length header, so we don't read anything.
        string body2 = "Goodbye, world.";
        HttpRequest r2 = new HttpRequestBuilder().withBody(body2).withoutHeader("Content-Length").build();
        auto app2 = appender!(ubyte[][]);
        ulong bytesRead2 = r2.readBody(app2);
        assert(bytesRead2 == 0);
        assert(app2[] == []);

        // Test case 3: Missing Content-Length header but we allow infinite reading.
        string body3 = "Hello moon!";
        HttpRequest r3 = new HttpRequestBuilder().withBody(body3).withoutHeader("Content-Length").build();
        auto app3 = appender!(ubyte[][]);
        ulong bytesRead3 = r3.readBody(app3, true);
        assert(bytesRead3 == body3.length);
        assert(app3[] == [cast(ubyte[]) body3]);
    }

    /** 
     * Internal helper method for reading the body of a request.
     * Params:
     *   outputRange = The output range to supply chunks of `ubyte[]` to.
     *   expectedLength = The expected size of the body to read. If this is
     *                    set to -1, then we'll read until there's nothing
     *                    left. Otherwise, we'll read as many bytes as given.
     * Returns: The number of bytes that were read.
     */
    private ulong readBody(R)(R outputRange, long expectedLength) if (isOutputRange!(R, ubyte[])) {
        auto log = getLogger();
        log.debugF!"Reading request body. Expected length: %d"(expectedLength);
        import std.algorithm : min;
        bool hasExpectedLength = expectedLength != -1;
        ulong bytesRead = 0;

        while (!this.inputRange.empty() && (!hasExpectedLength || bytesRead < expectedLength)) {
            ubyte[] data = this.inputRange.front();
            ulong bytesLeftToRead = expectedLength - bytesRead;
            size_t bytesToConsume = min(bytesLeftToRead, data.length);
            outputRange.put(data[0 .. bytesToConsume]);
            bytesRead += bytesToConsume;
            this.inputRange.popFront();
            log.debugF!"Consumed %d bytes."(bytesToConsume);
        }
        log.debugF!"Reading completed. Expected length: %d, Bytes read: %d"(expectedLength, bytesRead);
        if (hasExpectedLength && bytesRead < expectedLength) {
            throw new Exception("Connection closed before all data could be read.");
        }
        return bytesRead;
    }

    /** 
     * Convenience method for reading the entire request body as an array of
     * bytes.
     * Params:
     *   allowInfiniteRead = Whether to read until no more data is available.
     * Returns: The byte content of the request body.
     */
    public ubyte[] readBodyAsBytes(bool allowInfiniteRead = false) {
        Appender!(ubyte[]) app = appender!(ubyte[])();
        readBody(app, allowInfiniteRead);
        return app[];
    }

    /** 
     * Convenience method for reading the entire request body as a string.
     * Params:
     *   allowInfiniteRead = Whether to read until no more data is available.
     * Returns: The string contents of the request body.
     */
    public string readBodyAsString(bool allowInfiniteRead = false) {
        Appender!string app = appender!string();
        readBody(app, allowInfiniteRead);
        return app[];
    }

    /** 
     * Convenience method for reading the entire request body as a JSON node.
     * An exception will be thrown if the body cannot be parsed as JSON.
     * Params:
     *   allowInfiniteRead = Whether to read until no more data is available.
     * Returns: The request body as a JSON node.
     */
    public auto readBodyAsJson(bool allowInfiniteRead = false) {
        import std.json;
        return readBodyAsString(allowInfiniteRead).parseJSON();
    }

    /** 
     * Convenience method for reading the entire request body to a file.
     * Params:
     *   filename = The name of the file to write to.
     *   allowInfiniteRead = Whether to read until no more data is available.
     * Returns: The size of the received file, in bytes.
     */
    public ulong readBodyToFile(string filename, bool allowInfiniteRead = false) {
        import std.stdio : File;

        /** 
         * Simple wrapper for a range that dumps chunks of data into a file.
         */
        struct FileOutputRange {
            File file;
            void put(ubyte[] data) {
                file.rawWrite(data);
            }
        }

        File file = File(filename, "wb");
        FileOutputRange output = FileOutputRange(file);
        ulong bytesRead = readBody(output, allowInfiniteRead);
        file.close();
        return bytesRead;
    }
}

/** 
 * Enumeration of all possible HTTP request methods as unsigned integer values
 * for efficient logic.
 * 
 * https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods
 */
public enum Method : ushort {
    GET     = 1 << 0,
    HEAD    = 1 << 1,
    POST    = 1 << 2,
    PUT     = 1 << 3,
    DELETE  = 1 << 4,
    CONNECT = 1 << 5,
    OPTIONS = 1 << 6,
    TRACE   = 1 << 7,
    PATCH   = 1 << 8
}

import std.traits : EnumMembers;

/** 
 * Constant that defines the number of available methods.
 */
public static const METHOD_COUNT = [EnumMembers!Method].length;

/** 
 * Gets the zero-based index of a method enum value, useful for histograms.
 * Params:
 *   method = The method to get the index for.
 * Returns: The index of the method.
 */
public size_t methodIndex(Method method) {
    static foreach (i, member; EnumMembers!Method) {
        if (method == member) return i;
    }
    assert(0, "Not an enum member.");
}

/** 
 * Gets a method using a zero-based index of the method enum value.
 * Params:
 *   idx = The index to find the method by.
 * Returns: The method at the given index.
 */
public Method methodFromIndex(size_t idx) {
    static foreach (i, member; EnumMembers!Method) {
        if (i == idx) return member;
    }
    return Method.GET;
}

/** 
 * Gets a Method enum value from a string. Defaults to GET for unknown names.
 * Params:
 *   name = The string representation of the method.
 * Returns: The method enum value.
 */
public Method methodFromName(string name) {
    import std.string : toUpper, strip;
    name = toUpper(strip(name));
    switch (name) {
        case "GET":
            return Method.GET;
        case "HEAD":
            return Method.HEAD;
        case "POST":
            return Method.POST;
        case "PUT":
            return Method.PUT;
        case "DELETE":
            return Method.DELETE;
        case "CONNECT":
            return Method.CONNECT;
        case "OPTIONS":
            return Method.OPTIONS;
        case "TRACE":
            return Method.TRACE;
        case "PATCH":
            return Method.PATCH;
        default:
            return Method.GET;
    }
}

/** 
 * Gets the string representation of a Method enum value.
 * Params:
 *   method = The method enum value.
 * Returns: The string representation.
 */
public string methodToName(const Method method) {
    final switch (method) {
        case Method.GET:
            return "GET";
        case Method.HEAD:
            return "HEAD";
        case Method.POST:
            return "POST";
        case Method.PUT:
            return "PUT";
        case Method.DELETE:
            return "DELETE";
        case Method.CONNECT:
            return "CONNECT";
        case Method.OPTIONS:
            return "OPTIONS";
        case Method.TRACE:
            return "TRACE";
        case Method.PATCH:
            return "PATCH";
    }
}

/** 
 * Builds a bitmask from the given list of method names.
 * Params:
 *   names = The method names to use.
 * Returns: A bitmask where bits are active for each method in the given list.
 */
public ushort methodMaskFromNames(string[] names) {
    ushort mask = 0;
    foreach (name; names) mask |= methodFromName(name);
    return mask;
}

unittest {
    assert(methodMaskFromNames([]) == 0);
    assert((methodMaskFromNames(["GET"]) & Method.GET) > 0);
    auto m1 = methodMaskFromNames(["GET", "POST", "PATCH"]);
    assert((m1 & Method.GET) > 0);
    assert((m1 & Method.POST) > 0);
    assert((m1 & Method.PATCH) > 0);
    assert((m1 & Method.CONNECT) == 0);
}

/** 
 * Gets a mask that contains every method.
 * Returns: The bit mask.
 */
public ushort methodMaskFromAll() {
    import std.traits : EnumMembers;
    ushort mask;
    static foreach (member; EnumMembers!Method) {
        mask |= member;
    }
    return mask;
}

/** 
 * Converts a method mask to a list of strings representing method names.
 * Params:
 *   mask = The mask to convert.
 * Returns: A list of method names.
 */
public string[] methodMaskToStrings(const ushort mask) {
    import std.traits : EnumMembers;
    string[] names;
    static foreach (member; EnumMembers!Method) {
        if ((mask & member) > 0) names ~= methodToName(member);
    }
    return names;
}

unittest {
    assert(methodMaskToStrings(0) == []);
    assert(methodMaskToStrings(methodMaskFromNames(["GET"])) == ["GET"]);
    assert(methodMaskToStrings(methodMaskFromNames(["GET", "PUT"])) == ["GET", "PUT"]);
    // The resulting list should always be in enum order.
    assert(methodMaskToStrings(methodMaskFromNames(["PUT", "POST"])) == ["POST", "PUT"]);
}
