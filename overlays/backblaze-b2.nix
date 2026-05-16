final: prev: {
  backblaze-b2 = prev.backblaze-b2.overridePythonAttrs (oldAttrs: {
    # Disable the strict runtime dependency checks that are causing the build to fail
    # The package works fine with newer versions of these dependencies
    pythonRelaxDepsHook = true;
    pythonRelaxDeps = [ "tabulate" "docutils" ];
  });
}
