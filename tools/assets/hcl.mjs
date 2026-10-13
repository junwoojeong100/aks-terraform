// HCL (Terraform) grammar definition for highlight.js: the default highlight.js bundle has no HCL, so it is registered by hand.
export default function hcl(hljs) {
  const KEYWORDS = {
    keyword:
      'resource data variable output locals module provider terraform moved import removed check ' +
      'run mock_provider mock_resource mock_data override_data override_resource override_module variables assert ' +
      'expect_failures backend required_providers required_version lifecycle dynamic content ' +
      'provisioner connection for in if else endif endfor ephemeral',
    literal: 'true false null',
    built_in:
      'abs ceil floor log max min parseint pow signum chomp format formatlist indent join lower regex regexall ' +
      'replace split strrev substr title trim trimprefix trimsuffix trimspace upper startswith endswith alltrue anytrue ' +
      'chunklist coalesce coalescelist compact concat contains distinct element flatten index keys length lookup merge one ' +
      'range reverse setintersection setproduct setsubtract setunion slice sort sum transpose values zipmap ' +
      'base64decode base64encode jsondecode jsonencode yamldecode yamlencode tolist tomap toset tostring tonumber tobool ' +
      'try can type formatdate timestamp timeadd uuid cidrhost cidrnetmask cidrsubnet cidrsubnets sha256 sha1 md5 ' +
      'file fileexists templatefile nonsensitive sensitive',
  };

  const INTERPOLATION = {
    className: 'subst',
    begin: /\$\{/,
    end: /\}/,
    keywords: KEYWORDS,
    contains: [
      'self',
      { className: 'string', begin: /"/, end: /"/ },
    ],
  };

  const STRING = {
    className: 'string',
    begin: /"/,
    end: /"/,
    contains: [{ begin: /\\./ }, INTERPOLATION],
  };

  const HEREDOC = {
    className: 'string',
    begin: /<<-?(EOT|EOF|EOS|YAML|JSON|POLICY)\s*$/,
    end: /^\s*(EOT|EOF|EOS|YAML|JSON|POLICY)\s*$/,
    contains: [INTERPOLATION],
  };

  const REFERENCE = {
    className: 'variable',
    begin: /\b(?:var|local|module|data|each|count|self|path|terraform|ephemeral)\.[A-Za-z0-9_\-\[\]\.\*"]+/,
  };

  return {
    name: 'HCL',
    aliases: ['terraform', 'tf', 'tfvars'],
    keywords: KEYWORDS,
    contains: [
      hljs.HASH_COMMENT_MODE,
      hljs.C_LINE_COMMENT_MODE,
      hljs.C_BLOCK_COMMENT_MODE,
      HEREDOC,
      STRING,
      { className: 'number', begin: /\b\d+(?:\.\d+)?\b/ },
      { className: 'attr', begin: /^\s*[A-Za-z_][\w\-]*(?=\s*=[^=>])/ },
      { className: 'title.function', begin: /\b[a-z_][a-z0-9_]*(?=\()/ },
      REFERENCE,
      { className: 'operator', begin: /=>|==|!=|&&|\|\||<=|>=|\?|:/, relevance: 0 },
    ],
  };
}
