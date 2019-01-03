load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":genrule_repository.bzl", "genrule_repository")
load(":repository_locations.bzl", "REPOSITORY_LOCATIONS")
load(":target_recipes.bzl", "TARGET_RECIPES")
load(
    "@bazel_tools//tools/cpp:windows_cc_configure.bzl",
    "find_vc_path",
    "setup_vc_env_vars",
)
load("@bazel_tools//tools/cpp:lib_cc_configure.bzl", "get_env_var")

# dict of {build recipe name: longform extension name,}
PPC_SKIP_TARGETS = {"luajit": "envoy.filters.http.lua"}

# go version for rules_go
GO_VERSION = "1.10.4"

def _repository_impl(name, **kwargs):
    # `existing_rule_keys` contains the names of repositories that have already
    # been defined in the Bazel workspace. By skipping repos with existing keys,
    # users can override dependency versions by using standard Bazel repository
    # rules in their WORKSPACE files.
    existing_rule_keys = native.existing_rules().keys()
    if name in existing_rule_keys:
        # This repository has already been defined, probably because the user
        # wants to override the version. Do nothing.
        return

    loc_key = kwargs.pop("repository_key", name)
    location = REPOSITORY_LOCATIONS[loc_key]

    # Git tags are mutable. We want to depend on commit IDs instead. Give the
    # user a useful error if they accidentally specify a tag.
    if "tag" in location:
        fail(
            "Refusing to depend on Git tag %r for external dependency %r: use 'commit' instead." %
            (location["tag"], name),
        )

    # HTTP tarball at a given URL. Add a BUILD file if requested.
    http_archive(
        name = name,
        urls = location["urls"],
        sha256 = location["sha256"],
        strip_prefix = location.get("strip_prefix", ""),
        **kwargs
    )

def _build_recipe_repository_impl(ctxt):
    # modify the recipes list based on the build context
    recipes = _apply_dep_blacklist(ctxt, ctxt.attr.recipes)

    # Setup the build directory with links to the relevant files.
    ctxt.symlink(Label("//bazel:repositories.sh"), "repositories.sh")
    ctxt.symlink(Label("//bazel:repositories.bat"), "repositories.bat")
    ctxt.symlink(
        Label("//ci/build_container:build_and_install_deps.sh"),
        "build_and_install_deps.sh",
    )
    ctxt.symlink(Label("//ci/build_container:recipe_wrapper.sh"), "recipe_wrapper.sh")
    ctxt.symlink(Label("//ci/build_container:Makefile"), "Makefile")
    for r in recipes:
        ctxt.symlink(
            Label("//ci/build_container/build_recipes:" + r + ".sh"),
            "build_recipes/" + r + ".sh",
        )
    ctxt.symlink(Label("//ci/prebuilt:BUILD"), "BUILD")

    # Run the build script.
    command = []
    env = {}
    if ctxt.os.name.upper().startswith("WINDOWS"):
        vc_path = find_vc_path(ctxt)
        current_path = get_env_var(ctxt, "PATH", None, False)
        env = setup_vc_env_vars(ctxt, vc_path)
        env["PATH"] += (";%s" % current_path)
        env["CC"] = "cl"
        env["CXX"] = "cl"
        env["CXXFLAGS"] = "-DNDEBUG"
        env["CFLAGS"] = "-DNDEBUG"
        command = ["./repositories.bat"] + recipes
    else:
        command = ["./repositories.sh"] + recipes

    print("Fetching external dependencies...")
    result = ctxt.execute(
        command,
        environment = env,
        quiet = False,
    )
    print(result.stdout)
    print(result.stderr)
    print("External dep build exited with return code: %d" % result.return_code)
    if result.return_code != 0:
        print("\033[31;1m\033[48;5;226m External dependency build failed, check above log " +
              "for errors and ensure all prerequisites at " +
              "https://github.com/envoyproxy/envoy/blob/master/bazel/README.md#quick-start-bazel-build-for-developers are met.")

        # This error message doesn't appear to the user :( https://github.com/bazelbuild/bazel/issues/3683
        fail("External dep build failed")

def _default_envoy_build_config_impl(ctx):
    ctx.file("WORKSPACE", "")
    ctx.file("BUILD.bazel", "")
    ctx.symlink(ctx.attr.config, "extensions_build_config.bzl")

_default_envoy_build_config = repository_rule(
    implementation = _default_envoy_build_config_impl,
    attrs = {
        "config": attr.label(default = "@envoy//source/extensions:extensions_build_config.bzl"),
    },
)

def _default_envoy_api_impl(ctx):
    ctx.file("WORKSPACE", "")
    ctx.file("BUILD.bazel", "")
    api_dirs = [
        "bazel",
        "docs",
        "envoy",
        "examples",
        "test",
        "tools",
    ]
    for d in api_dirs:
        ctx.symlink(ctx.path(ctx.attr.api).dirname.get_child(d), d)

_default_envoy_api = repository_rule(
    implementation = _default_envoy_api_impl,
    attrs = {
        "api": attr.label(default = "@envoy//api:BUILD"),
    },
)

# Python dependencies. If these become non-trivial, we might be better off using a virtualenv to
# wrap them, but for now we can treat them as first-class Bazel.
def _python_deps():
    _repository_impl(
        name = "com_github_pallets_markupsafe",
        build_file = "@envoy//bazel/external:markupsafe.BUILD",
    )
    native.bind(
        name = "markupsafe",
        actual = "@com_github_pallets_markupsafe//:markupsafe",
    )
    _repository_impl(
        name = "com_github_pallets_jinja",
        build_file = "@envoy//bazel/external:jinja.BUILD",
    )
    native.bind(
        name = "jinja2",
        actual = "@com_github_pallets_jinja//:jinja2",
    )
    _repository_impl(
        name = "com_github_apache_thrift",
        build_file = "@envoy//bazel/external:apache_thrift.BUILD",
    )
    _repository_impl(
        name = "com_github_twitter_common_lang",
        build_file = "@envoy//bazel/external:twitter_common_lang.BUILD",
    )
    _repository_impl(
        name = "com_github_twitter_common_rpc",
        build_file = "@envoy//bazel/external:twitter_common_rpc.BUILD",
    )
    _repository_impl(
        name = "com_github_twitter_common_finagle_thrift",
        build_file = "@envoy//bazel/external:twitter_common_finagle_thrift.BUILD",
    )

# Bazel native C++ dependencies. For the dependencies that doesn't provide autoconf/automake builds.
def _cc_deps():
    _repository_impl("grpc_httpjson_transcoding")
    native.bind(
        name = "path_matcher",
        actual = "@grpc_httpjson_transcoding//src:path_matcher",
    )
    native.bind(
        name = "grpc_transcoding",
        actual = "@grpc_httpjson_transcoding//src:transcoding",
    )

def _go_deps(skip_targets):
    # Keep the skip_targets check around until Istio Proxy has stopped using
    # it to exclude the Go rules.
    if "io_bazel_rules_go" not in skip_targets:
        _repository_impl(
            name = "com_github_golang_protobuf",
            # These patches are to add BUILD files to golang/protobuf.
            # TODO(sesmith177): Remove this dependency when both:
            #   1. There's a release of golang/protobuf that includes
            #      https://github.com/golang/protobuf/commit/31e0d063dd98c052257e5b69eeb006818133f45c
            #   2. That release is included in rules_go
            patches = [
                "@io_bazel_rules_go//third_party:com_github_golang_protobuf-gazelle.patch",
                "@io_bazel_rules_go//third_party:com_github_golang_protobuf-extras.patch",
            ],
            patch_args = ["-p1"],
        )
        _repository_impl("io_bazel_rules_go")
        _repository_impl("bazel_gazelle")

def _envoy_api_deps():
    # Treat the data plane API as an external repo, this simplifies exporting the API to
    # https://github.com/envoyproxy/data-plane-api.
    if "envoy_api" not in native.existing_rules().keys():
        _default_envoy_api(name = "envoy_api")

    native.bind(
        name = "api_httpbody_protos",
        actual = "@googleapis//:api_httpbody_protos",
    )
    native.bind(
        name = "http_api_protos",
        actual = "@googleapis//:http_api_protos",
    )
    _repository_impl(
        name = "six_archive",
        build_file = "@com_google_protobuf//:six.BUILD",
    )
    native.bind(
        name = "six",
        actual = "@six_archive//:six",
    )

def envoy_dependencies(path = "@envoy_deps//", skip_targets = []):
    envoy_repository = repository_rule(
        implementation = _build_recipe_repository_impl,
        environ = [
            "CC",
            "CXX",
            "CFLAGS",
            "CXXFLAGS",
            "LD_LIBRARY_PATH",
        ],
        # Don't pretend we're in the sandbox, we do some evil stuff with envoy_dep_cache.
        local = True,
        attrs = {
            "recipes": attr.string_list(),
        },
    )

    # Ideally, we wouldn't have a single repository target for all dependencies, but instead one per
    # dependency, as suggested in #747. However, it's much faster to build all deps under a single
    # recursive make job and single make jobserver.
    recipes = depset()
    for t in TARGET_RECIPES:
        if t not in skip_targets:
            recipes += depset([TARGET_RECIPES[t]])

    envoy_repository(
        name = "envoy_deps",
        recipes = recipes.to_list(),
    )

    for t in TARGET_RECIPES:
        if t not in skip_targets:
            native.bind(
                name = t,
                actual = path + ":" + t,
            )

    # Treat Envoy's overall build config as an external repo, so projects that
    # build Envoy as a subcomponent can easily override the config.
    if "envoy_build_config" not in native.existing_rules().keys():
        _default_envoy_build_config(name = "envoy_build_config")

    # Binding to an alias pointing to the selected version of BoringSSL:
    # - BoringSSL FIPS from @boringssl_fips//:ssl,
    # - non-FIPS BoringSSL from @boringssl//:ssl.
    _boringssl()
    _boringssl_fips()
    native.bind(
        name = "ssl",
        actual = "@envoy//bazel:boringssl",
    )

    # The long repo names (`com_github_fmtlib_fmt` instead of `fmtlib`) are
    # semi-standard in the Bazel community, intended to avoid both duplicate
    # dependencies and name conflicts.
    _com_google_absl()
    _com_github_bombela_backward()
    _com_github_circonus_labs_libcircllhist()
    _com_github_cyan4973_xxhash()
    _com_github_eile_tclap()
    _com_github_fmtlib_fmt()
    _com_github_gabime_spdlog()
    _com_github_gcovr_gcovr()
    _com_github_google_libprotobuf_mutator()
    _io_opentracing_cpp()
    _com_lightstep_tracer_cpp()
    _com_github_datadog_dd_opentracing_cpp()
    _com_github_grpc_grpc()
    _com_github_google_jwt_verify()
    _com_github_nanopb_nanopb()
    _com_github_nodejs_http_parser()
    _com_github_tencent_rapidjson()
    _com_google_googletest()
    _com_google_protobuf()

    # Used for bundling gcovr into a relocatable .par file.
    _repository_impl("subpar")

    _python_deps()
    _cc_deps()
    _go_deps(skip_targets)
    _envoy_api_deps()

def _boringssl():
    _repository_impl("boringssl")

def _boringssl_fips():
    location = REPOSITORY_LOCATIONS["boringssl_fips"]
    genrule_repository(
        name = "boringssl_fips",
        urls = location["urls"],
        sha256 = location["sha256"],
        genrule_cmd_file = "@envoy//bazel/external:boringssl_fips.genrule_cmd",
        build_file = "@envoy//bazel/external:boringssl_fips.BUILD",
    )

def _com_github_bombela_backward():
    _repository_impl(
        name = "com_github_bombela_backward",
        build_file = "@envoy//bazel/external:backward.BUILD",
    )
    native.bind(
        name = "backward",
        actual = "@com_github_bombela_backward//:backward",
    )

def _com_github_circonus_labs_libcircllhist():
    _repository_impl(
        name = "com_github_circonus_labs_libcircllhist",
        build_file = "@envoy//bazel/external:libcircllhist.BUILD",
    )
    native.bind(
        name = "libcircllhist",
        actual = "@com_github_circonus_labs_libcircllhist//:libcircllhist",
    )

def _com_github_cyan4973_xxhash():
    _repository_impl(
        name = "com_github_cyan4973_xxhash",
        build_file = "@envoy//bazel/external:xxhash.BUILD",
    )
    native.bind(
        name = "xxhash",
        actual = "@com_github_cyan4973_xxhash//:xxhash",
    )

def _com_github_eile_tclap():
    _repository_impl(
        name = "com_github_eile_tclap",
        build_file = "@envoy//bazel/external:tclap.BUILD",
    )
    native.bind(
        name = "tclap",
        actual = "@com_github_eile_tclap//:tclap",
    )

def _com_github_fmtlib_fmt():
    _repository_impl(
        name = "com_github_fmtlib_fmt",
        build_file = "@envoy//bazel/external:fmtlib.BUILD",
    )
    native.bind(
        name = "fmtlib",
        actual = "@com_github_fmtlib_fmt//:fmtlib",
    )

def _com_github_gabime_spdlog():
    _repository_impl(
        name = "com_github_gabime_spdlog",
        build_file = "@envoy//bazel/external:spdlog.BUILD",
    )
    native.bind(
        name = "spdlog",
        actual = "@com_github_gabime_spdlog//:spdlog",
    )

def _com_github_gcovr_gcovr():
    _repository_impl(
        name = "com_github_gcovr_gcovr",
        build_file = "@envoy//bazel/external:gcovr.BUILD",
    )
    native.bind(
        name = "gcovr",
        actual = "@com_github_gcovr_gcovr//:gcovr",
    )

def _com_github_google_libprotobuf_mutator():
    _repository_impl(
        name = "com_github_google_libprotobuf_mutator",
        build_file = "@envoy//bazel/external:libprotobuf_mutator.BUILD",
    )
    native.bind(
        name = "libprotobuf_mutator",
        actual = "@com_github_google_libprotobuf_mutator//:libprotobuf_mutator",
    )

def _io_opentracing_cpp():
    _repository_impl("io_opentracing_cpp")
    native.bind(
        name = "opentracing",
        actual = "@io_opentracing_cpp//:opentracing",
    )

def _com_lightstep_tracer_cpp():
    _repository_impl("com_lightstep_tracer_cpp")
    _repository_impl(
        name = "lightstep_vendored_googleapis",
        build_file = "@com_lightstep_tracer_cpp//:lightstep-tracer-common/third_party/googleapis/BUILD",
    )
    native.bind(
        name = "lightstep",
        actual = "@com_lightstep_tracer_cpp//:lightstep_tracer",
    )

def _com_github_datadog_dd_opentracing_cpp():
    _repository_impl("com_github_datadog_dd_opentracing_cpp")
    _repository_impl(
        name = "com_github_msgpack_msgpack_c",
        build_file = "@com_github_datadog_dd_opentracing_cpp//:bazel/external/msgpack.BUILD",
    )
    native.bind(
        name = "dd_opentracing_cpp",
        actual = "@com_github_datadog_dd_opentracing_cpp//:dd_opentracing_cpp",
    )

def _com_github_tencent_rapidjson():
    _repository_impl(
        name = "com_github_tencent_rapidjson",
        build_file = "@envoy//bazel/external:rapidjson.BUILD",
    )
    native.bind(
        name = "rapidjson",
        actual = "@com_github_tencent_rapidjson//:rapidjson",
    )

def _com_github_nodejs_http_parser():
    _repository_impl(
        name = "com_github_nodejs_http_parser",
        build_file = "@envoy//bazel/external:http-parser.BUILD",
    )
    native.bind(
        name = "http_parser",
        actual = "@com_github_nodejs_http_parser//:http_parser",
    )

def _com_google_googletest():
    _repository_impl("com_google_googletest")
    native.bind(
        name = "googletest",
        actual = "@com_google_googletest//:gtest",
    )

# TODO(jmarantz): replace the use of bind and external_deps with just
# the direct Bazel path at all sites.  This will make it easier to
# pull in more bits of abseil as needed, and is now the preferred
# method for pure Bazel deps.
def _com_google_absl():
    _repository_impl("com_google_absl")
    native.bind(
        name = "abseil_any",
        actual = "@com_google_absl//absl/types:any",
    )
    native.bind(
        name = "abseil_base",
        actual = "@com_google_absl//absl/base:base",
    )
    native.bind(
        name = "abseil_flat_hash_map",
        actual = "@com_google_absl//absl/container:flat_hash_map",
    )
    native.bind(
        name = "abseil_flat_hash_set",
        actual = "@com_google_absl//absl/container:flat_hash_set",
    )
    native.bind(
        name = "abseil_strings",
        actual = "@com_google_absl//absl/strings:strings",
    )
    native.bind(
        name = "abseil_int128",
        actual = "@com_google_absl//absl/numeric:int128",
    )
    native.bind(
        name = "abseil_optional",
        actual = "@com_google_absl//absl/types:optional",
    )
    native.bind(
        name = "abseil_synchronization",
        actual = "@com_google_absl//absl/synchronization:synchronization",
    )
    native.bind(
        name = "abseil_symbolize",
        actual = "@com_google_absl//absl/debugging:symbolize",
    )

    # Require abseil_time as an indirect dependency as it is needed by the
    # direct dependency jwt_verify_lib.
    native.bind(
        name = "abseil_time",
        actual = "@com_google_absl//absl/time:time",
    )

def _com_google_protobuf():
    _repository_impl("com_google_protobuf")

    # Needed for cc_proto_library, Bazel doesn't support aliases today for repos,
    # see https://groups.google.com/forum/#!topic/bazel-discuss/859ybHQZnuI and
    # https://github.com/bazelbuild/bazel/issues/3219.
    _repository_impl(
        "com_google_protobuf_cc",
        repository_key = "com_google_protobuf",
    )
    native.bind(
        name = "protobuf",
        actual = "@com_google_protobuf//:protobuf",
    )
    native.bind(
        name = "protobuf_clib",
        actual = "@com_google_protobuf//:protoc_lib",
    )
    native.bind(
        name = "protocol_compiler",
        actual = "@com_google_protobuf//:protoc",
    )
    native.bind(
        name = "protoc",
        actual = "@com_google_protobuf_cc//:protoc",
    )

    # Needed for `bazel fetch` to work with @com_google_protobuf
    # https://github.com/google/protobuf/blob/v3.6.1/util/python/BUILD#L6-L9
    native.bind(
        name = "python_headers",
        actual = "@com_google_protobuf//util/python:python_headers",
    )

def _com_github_grpc_grpc():
    _repository_impl("com_github_grpc_grpc")

    # Rebind some stuff to match what the gRPC Bazel is expecting.
    native.bind(
        name = "protobuf_headers",
        actual = "@com_google_protobuf//:protobuf_headers",
    )
    native.bind(
        name = "libssl",
        actual = "//external:ssl",
    )
    native.bind(
        name = "cares",
        actual = "//external:ares",
    )

    native.bind(
        name = "grpc",
        actual = "@com_github_grpc_grpc//:grpc++",
    )

    native.bind(
        name = "grpc_health_proto",
        actual = "@envoy//bazel:grpc_health_proto",
    )

    native.bind(
        name = "grpc_alts_fake_handshaker_server",
        actual = "@com_github_grpc_grpc//test/core/tsi/alts/fake_handshaker:fake_handshaker_lib",
    )

def _com_github_nanopb_nanopb():
    _repository_impl(
        name = "com_github_nanopb_nanopb",
        build_file = "@com_github_grpc_grpc//third_party:nanopb.BUILD",
    )

    native.bind(
        name = "nanopb",
        actual = "@com_github_nanopb_nanopb//:nanopb",
    )

def _com_github_google_jwt_verify():
    _repository_impl("com_github_google_jwt_verify")

    native.bind(
        name = "jwt_verify_lib",
        actual = "@com_github_google_jwt_verify//:jwt_verify_lib",
    )

def _apply_dep_blacklist(ctxt, recipes):
    newlist = []
    skip_list = []
    if _is_linux_ppc(ctxt):
        skip_list += PPC_SKIP_TARGETS.keys()
    for t in recipes:
        if t not in skip_list:
            newlist.append(t)
    return newlist

def _is_linux(ctxt):
    return ctxt.os.name == "linux"

def _is_arch(ctxt, arch):
    res = ctxt.execute(["uname", "-m"])
    return arch in res.stdout

def _is_linux_ppc(ctxt):
    return _is_linux(ctxt) and _is_arch(ctxt, "ppc")

def _is_linux_x86_64(ctxt):
    return _is_linux(ctxt) and _is_arch(ctxt, "x86_64")
