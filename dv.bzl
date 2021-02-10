"""
Rules for building DV infrastructure.
"""

load("//:verilog.bzl", "VerilogLibFiles", "flists_to_arguments", "get_transitive_srcs", "gather_shell_defines")

DVTestCfg = provider(fields = {
    "sim_opts": "Simulation options",
    "uvm_testname": "UVM Test Name",
    "vcomp": "Label of type dv_tb",
    "tags" : "Tags",
})

DVTB = provider(fields = {
    "ccf" : "Coverage config file",
})

def _dv_test_cfg_impl(ctx):
    parent_uvm_testnames = [dep[DVTestCfg].uvm_testname for dep in reversed(ctx.attr.inherits) if hasattr(dep[DVTestCfg], "uvm_testname")]
    parent_vcomps = [dep[DVTestCfg].vcomp for dep in reversed(ctx.attr.inherits) if hasattr(dep[DVTestCfg], "vcomp")]

    sim_opts = {}
    # Each successive depdency may override previous deps
    for dep in ctx.attr.inherits:
        sim_opts.update(dep[DVTestCfg].sim_opts)
    # This rule instance may override previous sim_opts
    sim_opts.update(ctx.attr.sim_opts)

    provider_args = {}

    uvm_testname = None
    if ctx.attr.uvm_testname:
        uvm_testname = ctx.attr.uvm_testname
    elif len(parent_uvm_testnames):
        uvm_testname = parent_uvm_testnames[0]
    else:
        uvm_testname = ctx.attr.name

    vcomp = None
    if ctx.attr.vcomp:
        vcomp = ctx.attr.vcomp
    else:
        vcomp = parent_vcomps[0]

    provider_args["uvm_testname"] = uvm_testname
    provider_args["vcomp"] = vcomp
    provider_args["sim_opts"] = sim_opts
    provider_args["tags"] = ctx.attr.tags

    sim_opts_str = "\n".join(["{}{}".format(key, value) for key, value in sim_opts.items()])

    out = ctx.outputs.sim_args
    ctx.actions.write(
        output = out,
        content = """+UVM_TESTNAME={uvm_testname}\n{sim_opts}""".format(
            uvm_testname = uvm_testname,
            sim_opts = sim_opts_str,
        ),
    )

    for socket_name, socket_command in ctx.attr.sockets.items():
        if "{socket_file}" not in socket_command:
            fail("socket {} did not have {{socket_file}} in socket_command".format(socket_name))

    dynamic_args = {'sockets' : ctx.attr.sockets}
    out = ctx.outputs.dynamic_args
    ctx.actions.write(
        output = out,
        content = str(dynamic_args),
    )
    return [DVTestCfg(**provider_args)]

dv_test_cfg = rule(
    doc = "A DV test configuration. This is not a executable target.",
    implementation = _dv_test_cfg_impl,
    attrs = {
        "abstract": attr.bool(default = False, doc = "This configuration is abstract. It is not intended to be excuted, but only to be used as a base for other test configurations."),
        "inherits": attr.label_list(doc = "Inherit configurations from dv_test_cfg targets. Entries later in the list will override arguements set by previous inherits entries. Any field explicily set in this rule will override values set through inheritance."),
        "uvm_testname": attr.string(doc = "UVM testname. If not set, finds from deps."),
        "vcomp": attr.label(doc = "Must point to a 'dv_tb' target for how to build this testbench."),
        "sim_opts": attr.string_dict(doc = "Additional simopts flags to throw"),
        "no_run" : attr.bool(default = False, doc = "Set to True to skip running this test."),
        "sockets" : attr.string_dict(
            doc = "\n".join([
                "Dictionary mapping of socket_name to socket_command.",
                "For each entry in the list, simmer will create a separate process and pass a unique temporary file path to both the simulator and the socket_command.",
                "The socket name is a short identifier that will be passed as \"+SOCKET__<socket_name>=<socket_file>\" to the simulator.",
                "The socket_file is just a filepath to a temporary file in the simulation results directory (for uniqueness)",
                "The socket_command is a bash command that must use a python string formatter of \"{socket_file}\" somewhere in the command.",
                "The socket_command will be run from the root of the project tree.",
            ]),
        ),
    },
    outputs = {
        "sim_args": "%{name}_sim_args.f",
        "dynamic_args" : "%{name}_dynamic_args.py",
    },
)


def _dv_lib_impl(ctx):
    if ctx.attr.incdir:
        # Using dirname may result in bazel-out included in path 
        directories = depset([f.short_path[:-len(f.basename)-1] for f in ctx.files.srcs ]).to_list()
    else:
        directories = []

    # # Add output files from direct dependencies (from genrules)
    srcs = depset(ctx.files.srcs, transitive = [dep[DefaultInfo].files for dep in ctx.attr.deps if VerilogLibFiles not in dep])

    if len(ctx.files.in_flist):
        in_flist = ctx.files.in_flist
    else:
        in_flist = ctx.files.srcs

    content = []
    for d in directories:
        if d == "":
            d = "."
        content.append("+incdir+{}".format(d))
    for f in in_flist:
        content.append(f.short_path)

    all_sos = []
    for dpi in ctx.attr.dpi:
        sos = []
        for gfile in dpi[DefaultInfo].files.to_list():
            if gfile.path.endswith(".so"):
                sos.append(gfile)
        if len(sos) != 1:
            fail("Expected to find exactly one .so for dv_lib dpi argument '", dpi, "'. Found .so: ", sos)
        all_sos.extend(sos)

    out = ctx.outputs.out
    ctx.actions.write(
        output = out,
        content = "\n".join(content),
    )

    trans_srcs = get_transitive_srcs(ctx.files.srcs, ctx.attr.deps + ctx.attr.dpi, VerilogLibFiles, "transitive_sources", allow_other_outputs = True)
    trans_flists = get_transitive_srcs([out], ctx.attr.deps, VerilogLibFiles, "transitive_flists", allow_other_outputs = False)
    trans_dpi = get_transitive_srcs(all_sos, ctx.attr.deps, VerilogLibFiles, "transitive_dpi", allow_other_outputs = False)

    all_files = depset(trans_srcs.to_list() + trans_flists.to_list())

    return [
        VerilogLibFiles(transitive_sources = trans_srcs, transitive_flists = trans_flists, transitive_dpi = trans_dpi),
        DefaultInfo(
            files = all_files,
            runfiles = ctx.runfiles(files = trans_srcs.to_list() + trans_flists.to_list()),
        ),
    ]

dv_lib = rule(
    doc = "An DV Library. Creates a generated flist file from a list of source files.",
    implementation = _dv_lib_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "deps": attr.label_list(),
        "in_flist": attr.label_list(
            allow_files = True,
            doc = "Files to be places in generated flist. Generally only the 'pkg' file and interfaces. If left blank, all srcs will be used.",
        ),
        "dpi": attr.label_list(doc = "cc_libraries to link in through dpi"),
        "incdir" : attr.bool(default = True, doc = "Include an incdir to src file directories in generated flist."),
    },
    outputs = {"out": "%{name}.f"},
)

_XRUN_COMPILE_ARGS_TEMPLATE = "//:xrun_compile_args_template.txt"
_XRUN_RUNTIME_ARGS_TEMPLATE = "//:xrun_runtime_args_template.txt"

def _dv_tb_impl(ctx):

    defines = {}
    defines.update(ctx.attr.defines)
    defines.update(gather_shell_defines(ctx.attr.shells))

    ctx.actions.expand_template(
        template = ctx.file._compile_args_template,
        output = ctx.outputs.compile_args,
        substitutions = {
            "{COMPILE_ARGS}" : ctx.expand_location("\n".join(ctx.attr.extra_compile_args), targets=ctx.attr.extra_runfiles),
            "{DEFINES}" : "\n".join(["-define {}{}".format(key, value) for key, value in defines.items()]),
            "{FLISTS}": flists_to_arguments(ctx.attr.shells + ctx.attr.deps, VerilogLibFiles, "transitive_flists", "\n-f"),
        },
    )

    ctx.actions.write(
        output = ctx.outputs.compile_warning_waivers,
        content = "[\n" + "\n".join(["re.compile('{}'),".format(ww) for ww in ctx.attr.warning_waivers]) + "\n]\n",
    )

    ctx.actions.expand_template(
        template = ctx.file._runtime_args_template,
        output = ctx.outputs.runtime_args,
        substitutions = {
            "{RUNTIME_ARGS}" : ctx.expand_location("\n".join(ctx.attr.extra_runtime_args), targets=ctx.attr.extra_runfiles),
            "{DPI_LIBS}": flists_to_arguments(ctx.attr.shells + ctx.attr.deps, VerilogLibFiles, "transitive_dpi", "-sv_lib"),
        },
    )

    # Null action to trigger run?
    ctx.actions.run_shell(
        command = "echo \"Build compile tree directory in \"`pwd`; touch {}".format(ctx.outputs.executable.path),
        outputs = [ctx.outputs.executable],
    )

    trans_srcs = get_transitive_srcs([], ctx.attr.deps + ctx.attr.shells, VerilogLibFiles, "transitive_sources", allow_other_outputs = True)
    trans_flists = get_transitive_srcs([], ctx.attr.deps + ctx.attr.shells, VerilogLibFiles, "transitive_flists", allow_other_outputs = False)

    out_deps = depset([ctx.outputs.compile_args, ctx.outputs.runtime_args, ctx.outputs.compile_warning_waivers, ctx.outputs.executable])

    all_files = depset([], transitive=[trans_srcs, trans_flists, out_deps])
    return [
        DefaultInfo(
            files = all_files,
            runfiles = ctx.runfiles(files = trans_srcs.to_list() + trans_flists.to_list() + out_deps.to_list() + ctx.files.ccf + ctx.files.extra_runfiles + [ctx.file._default_sim_opts]),
        ),
        DVTB(
            ccf = ctx.files.ccf,
        ),
    ]

dv_tb = rule(
    doc = "A DV Testbench.",
    implementation = _dv_tb_impl,
    attrs = {
        "deps": attr.label_list(mandatory = True),
        "defines": attr.string_dict(doc = "Additional defines to throw for this testbench compile."),
        "warning_waivers" : attr.string_list(doc = "Waive warnings in the compile. Converted to python regular expressions"),
        "shells" : attr.label_list(doc =
                                   "List of shells to use.\n" +
                                   "Each shell thrown will create two defines:\n" + 
                                   " `define gumi_<module> <module>_shell\n" +
                                   " `define gumi_use_<module>_shell\n" +
                                   "The shell module declaration must be guarded by the gumi_use_<module>_shell define:\n" +
                                   " `ifdef gumi_use_<module>_shell\n" +
                                   "    module <module>_shell(/*AUTOARGS*/);\n" +
                                   "      ...\n" +
                                   "    endmodule\n" +
                                   " `endif\n"
                               ),
        "ccf" : attr.label_list(allow_files = True,
                                doc = "Coverage configuration file",
                            ),
        "extra_compile_args" : attr.string_list(doc = "Additional flags to throw to compile"),
        "extra_runtime_args" : attr.string_list(doc = "Additional flags to throw to simultation run"),
        "extra_runfiles" : attr.label_list(
            allow_files = True,
            doc = "Additional files that need to be passed as runfiles to bazel. The generally should only be things referred to by extra_compile_args or extra_runtime_args",
        ),
        "_default_sim_opts": attr.label(
            allow_single_file = True,
            default = "//:default_sim_opts.f",
        ),
        "_compile_args_template": attr.label(
            default = Label(_XRUN_COMPILE_ARGS_TEMPLATE),
            allow_single_file = True,
        ),
        "_runtime_args_template": attr.label(
            default = Label(_XRUN_RUNTIME_ARGS_TEMPLATE),
            allow_single_file = True,
        ),
    },
    outputs = {
        "compile_args": "%{name}_compile_args",
        "compile_warning_waivers": "%{name}_compile_warning_waivers",
        "runtime_args": "%{name}_runtime_args",
    },
    executable = True,
)

def _dv_unit_test_impl(ctx):
    trans_srcs = get_transitive_srcs([], ctx.attr.deps, VerilogLibFiles, "transitive_sources")
    srcs_list = trans_srcs.to_list()
    flists = get_transitive_srcs([], ctx.attr.deps, VerilogLibFiles, "transitive_flists")
    flists_list = flists.to_list()

    ctx.actions.expand_template(
        template = ctx.file._ut_sim_template,
        output = ctx.outputs.out,
        substitutions = {
            "{DEFAULT_SIM_OPTS}": "-f {}".format(ctx.file.default_sim_opts.short_path),
            "{DPI_LIBS}": flists_to_arguments(ctx.attr.deps, VerilogLibFiles, "transitive_dpi", "-sv_lib"),
            "{FLISTS}": " ".join(["-f {}".format(f.short_path) for f in flists_list]),
            "{SIM_ARGS}": " ".join(ctx.attr.sim_args),
        },
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = flists_list + srcs_list + [ctx.file.default_sim_opts])
    return [DefaultInfo(
        runfiles = runfiles,
        executable = ctx.outputs.out,
    )]

dv_unit_test = rule(
    # FIXME, this should eventually just be a specific use case of verilog_test
    doc = """Compiles and runs a small DV library. Additional sim options may be passed after --
    Interactive example:
      bazel run //digital/dv/interfaces/apb_pkg:test -- -gui
    For ci testing purposes:
      bazel test //digital/dv/interfaces/apb_pkg:test
    """,
    implementation = _dv_unit_test_impl,
    attrs = {
        "deps": attr.label_list(mandatory = True),
        "_ut_sim_template": attr.label(
            allow_single_file = True,
            default = Label("//:ut_sim_template.sh"),
        ),
        "default_sim_opts": attr.label(
            allow_single_file = True,
            default = "//:default_sim_opts.f",
        ),
        "sim_args": attr.string_list(doc = "Additional simulation arguments to passed to command line"),
    },
    outputs = {"out": "%{name}_run.sh"},
    test = True,
)


# Used by simmer to find test to tb/vcomp mappings
def _test_to_vcomp_aspect_impl(target, ctx):
    print("test_to_vcomp({}, {}, {})".format(target.label, target[DVTestCfg].vcomp.label, target[DVTestCfg].tags))
    return []

test_to_vcomp_aspect = aspect(
    implementation = _test_to_vcomp_aspect_impl,
    attr_aspects = ['deps', 'tags'],
)

# Used by simmer to find test to find ccf file
def _dv_tb_ccf_aspect_impl(target, ctx):
    print("dv_tb_ccf({})".format([f.path for f in target[DVTB].ccf]))
    return []

dv_tb_ccf_aspect = aspect(
    implementation = _dv_tb_ccf_aspect_impl,
    attr_aspects = ['ccf'],
)
