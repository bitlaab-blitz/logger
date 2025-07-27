# How to use

First, import Jwt on your Zig source file.

```zig
const jwt = @import("jwt");
```

Now, add the following code into your main function.

```zig
var gpa_mem = std.heap.DebugAllocator(.{}).init;
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();
```

## Encode a JWT Token

Here, `Userdata` is a custom struct that holds application-specific authentication details.

```zig
const Userdata = struct {
    role: []const u8,
    feature: []const []const u8
};

const key = "secret";

const token = try jwt.Jws(Userdata).encode(heap, key, .{
    .sub = "john",
    .iss = "example.com",
    .aud = "hydra",
    .data = .{
        .role = "admin",
        .feature = &.{"foo", "bar"}
    },
    .iat = jwt.setTime(.Second, 0),
    .nbf = jwt.setTime(.Second, 0),
    .exp = jwt.setTime(.Minute, 2),
});
defer heap.free(token);

std.debug.print("JWT Token: {s}\n", .{token});
```

## Decode a JWT Token

Token validation is handled internally, which automatically verifies the signature, checks required claims such as exp (expiration), nbf (not before), and ensures the token is structurally valid and not tampered with. 

```zig
const token = "your jwt token...";

const claims = try jwt.Jws(Userdata).decode(heap, key, token);
std.debug.print("{any}\n", .{claims});
try jwt.free(heap, claims);
```
