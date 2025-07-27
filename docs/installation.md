# How to Install

Navigate to your project directory. e.g., `cd my_awesome_project`

### Install the Nightly Version

Fetch **jwt** as external package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-blitz/jwt/archive/refs/heads/main.zip
```

### Install the Release Version

Fetch **jwt** as external package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-blitz/jwt/archive/refs/tags/v0.0.0.zip
```

Make sure to edit `v0.0.0` with the latest release version.

## Import Module

Now, import **jwt** as external package module to your project by coping following code:

```zig title="build.zig"
const jwt = b.dependency("jwt", .{});
exe.root_module.addImport("jwt", jwt.module("jwt"));
lib.root_module.addImport("jwt", jwt.module("jwt"));
```
