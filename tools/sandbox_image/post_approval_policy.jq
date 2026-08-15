def nonempty_string:
  type == "string" and length > 0;

def same_identity($finding; $disposition):
  $finding.vulnerability_id == $disposition.vulnerability_id and
  $finding.package == $disposition.package and
  $finding.result_class == $disposition.result_class and
  $finding.result_type == $disposition.result_type and
  $finding.target == $disposition.target;

if ($scan | length) != 1 or
   ($disposition_documents | length) != 1 then
  error("scan or disposition input is not one JSON document")
else
  $scan[0] as $document |
  $disposition_documents[0] as $dispositions |
  if ($document | type) != "object" or
     ($document.Results | type) != "array" or
     (any($document.Results[]; .Class == "os-pkgs") | not) or
     (all($document.Results[];
       (.Class == "os-pkgs" or .Class == "lang-pkgs") and
       (.Type | nonempty_string) and
       (.Target | nonempty_string) and
       ((.Vulnerabilities // []) | type) == "array" and
       all((.Vulnerabilities // [])[];
         (.VulnerabilityID | nonempty_string) and
         (.PkgName | nonempty_string) and
         ((.Severity | ascii_upcase) |
           IN("UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL")) and
         (.FixedVersion == null or
           (.FixedVersion | type) == "string"))) | not) then
    error("Trivy vulnerability report has an invalid schema")
  elif ($dispositions | type) != "array" or
       (all($dispositions[];
         type == "object" and
         (keys | sort) == [
           "expires", "owner", "package", "rationale",
           "result_class", "result_type", "target", "vulnerability_id"
         ] and
         all(.[]; type == "string") and
         (.vulnerability_id | nonempty_string) and
         (.package | nonempty_string) and
         (.result_class | IN("os-pkgs", "lang-pkgs")) and
         (.result_type | nonempty_string) and
         (.target | nonempty_string) and
         (.rationale | test("\\S")) and
         (.owner | test("\\S")) and
         (.expires >= $today) and
         (try ((.expires + "T00:00:00Z") |
           fromdateiso8601 | type == "number") catch false)) | not) or
       ([$dispositions[] | [
         .vulnerability_id, .package, .result_class, .result_type, .target
       ]] | length) !=
       ([$dispositions[] | [
         .vulnerability_id, .package, .result_class, .result_type, .target
       ]] | unique | length) then
    error("vulnerability dispositions have an invalid schema")
  else
    [
      $document.Results[] as $result |
      ($result.Vulnerabilities // [])[] |
      {
        vulnerability_id: .VulnerabilityID,
        package: .PkgName,
        result_class: $result.Class,
        result_type: $result.Type,
        target: (
          if $result.Class == "os-pkgs" then "rootfs" else $result.Target end
        ),
        severity: (.Severity | ascii_upcase),
        fixed_version: (.FixedVersion // "")
      }
    ] as $findings |
    [
      $findings[] |
      select(.severity == "HIGH" or .severity == "CRITICAL") |
      . as $finding |
      select(
        (.fixed_version | length) > 0 or
        (any($dispositions[]; same_identity($finding; .)) | not)
      )
    ] as $blocking |
    [
      $dispositions[] as $disposition |
      select(any($findings[];
        (.severity == "HIGH" or .severity == "CRITICAL") and
        same_identity(.; $disposition)) | not) |
      $disposition
    ] as $unmatched |
    if $blocking == [] and $unmatched == [] then
      {blocking: [], unmatched_dispositions: []}
    else
      error("post-approval vulnerability policy failed")
    end
  end
end
