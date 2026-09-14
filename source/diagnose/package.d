/// `import diagnose;` pulls in the whole library; `import diagnose.diagnostics;`
/// etc. still works for module-qualified access only.
module diagnose;

public import diagnose.diagnostics;
public import diagnose.source_location;
