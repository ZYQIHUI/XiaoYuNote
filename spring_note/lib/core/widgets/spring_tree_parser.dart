/// Parser for `springtree` code blocks.
///
/// Turns a Markdown indented list into a tree that can be rendered as a
/// mind map. The parser is a single pass over the lines with a small stack,
/// so it runs in O(n) and is fast enough to re-run on every streaming delta
/// (typically well under 0.1 ms for chat-sized input).
///
/// Fault tolerance rules:
/// - blank lines, horizontal rules and lines that become empty after cleanup
///   are skipped;
/// - list markers (`-`, `*`, `+`, `1.` …) and task checkboxes are optional —
///   plain indented text works too;
/// - indentation is compared relatively, so mixed tab/space widths and jumps
///   of more than one level still produce a sane tree (the deepest line with
///   a smaller indent becomes the parent);
/// - inline Markdown (links, bold, code, images, HTML tags) is reduced to
///   readable plain text;
/// - the node count is capped so pathological input cannot blow up layout.
library;

/// A single node of a parsed springtree.
class SpringTreeNode {
  SpringTreeNode({required this.id, required this.label, required this.depth});

  /// Stable path id, e.g. `0`, `0.2`, `0.2.1`. Appending new lines during
  /// streaming keeps every existing id unchanged, which lets the widget
  /// animate only the genuinely new nodes.
  final String id;
  final String label;
  final int depth;
  final List<SpringTreeNode> children = <SpringTreeNode>[];

  int get leafCount {
    if (children.isEmpty) {
      return 1;
    }
    var count = 0;
    for (final child in children) {
      count += child.leafCount;
    }
    return count;
  }
}

/// Result of [parseSpringTree].
class SpringTree {
  const SpringTree(this.roots, this.nodeCount);

  /// Top-level nodes. More than one root is allowed; the widget joins them
  /// under a hidden origin node.
  final List<SpringTreeNode> roots;
  final int nodeCount;

  bool get isEmpty => roots.isEmpty;

  int get leafCount {
    var count = 0;
    for (final root in roots) {
      count += root.leafCount;
    }
    return count;
  }
}

const int _maxNodes = 300;
const int _maxLabelLength = 120;
const int _tabWidth = 4;

final RegExp _indentPattern = RegExp(r'^[ \t]*');
final RegExp _listMarkerPattern = RegExp(
  r'^(?:[-+*]|\d{1,9}[.)])(?:[ \t]+\[[ xX]?\])?[ \t]+',
);
final RegExp _headingPattern = RegExp(r'^#{1,6}[ \t]+');
final RegExp _horizontalRulePattern = RegExp(r'^\s*([-*_])(?:\s*\1){2,}\s*$');
final RegExp _loneMarkerPattern = RegExp(r'^(?:[-+*]|\d{1,9}[.)])$');
final RegExp _imagePattern = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final RegExp _linkPattern = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final RegExp _inlineCodePattern = RegExp(r'`([^`]*)`');
final RegExp _boldPattern = RegExp(r'(\*\*|__)(.*?)\1');
final RegExp _italicPattern = RegExp(r'\*([^*\n]+)\*');
final RegExp _strikePattern = RegExp(r'~~(.*?)~~');
final RegExp _htmlTagPattern = RegExp(r'<[^>]*>');
final RegExp _whitespacePattern = RegExp(r'\s+');

/// Parses [source] (the body of a ```springtree fence) into a [SpringTree].
SpringTree parseSpringTree(String source) {
  final roots = <SpringTreeNode>[];
  // Parallel stacks: indent of each open node and the node itself.
  // The bottom sentinel (indent -1, node null) represents the virtual root.
  final indentStack = <int>[-1];
  final nodeStack = <SpringTreeNode?>[null];
  var nodeCount = 0;

  for (final rawLine in source.split('\n')) {
    if (nodeCount >= _maxNodes) {
      break;
    }
    final line = rawLine.trimRight();
    if (line.trimLeft().isEmpty || _horizontalRulePattern.hasMatch(line)) {
      continue;
    }

    final indentText = _indentPattern.firstMatch(line)!.group(0)!;
    final indent = _measureIndent(indentText);
    var content = line.substring(indentText.length);
    if (_loneMarkerPattern.hasMatch(content)) {
      // A marker with no text (e.g. a trailing `- `) carries no information.
      continue;
    }
    content = content.replaceFirst(_listMarkerPattern, '');
    content = content.replaceFirst(_headingPattern, '');
    final label = _cleanLabel(content);
    if (label.isEmpty) {
      continue;
    }

    // The parent is the deepest open node with a strictly smaller indent.
    // Popping on >= also keeps equal-indent lines as siblings.
    while (indentStack.last >= indent) {
      indentStack.removeLast();
      nodeStack.removeLast();
    }

    final parent = nodeStack.last;
    final id = parent == null
        ? '${roots.length}'
        : '${parent.id}.${parent.children.length}';
    final node = SpringTreeNode(
      id: id,
      label: label,
      depth: nodeStack.length - 1,
    );
    if (parent == null) {
      roots.add(node);
    } else {
      parent.children.add(node);
    }
    indentStack.add(indent);
    nodeStack.add(node);
    nodeCount++;
  }

  return SpringTree(roots, nodeCount);
}

int _measureIndent(String indentText) {
  var width = 0;
  for (var i = 0; i < indentText.length; i++) {
    if (indentText.codeUnitAt(i) == 0x09) {
      width += _tabWidth - (width % _tabWidth);
    } else {
      width += 1;
    }
  }
  return width;
}

/// Reduces inline Markdown to plain text so node labels stay readable.
String _cleanLabel(String raw) {
  var text = raw
      .replaceAllMapped(_imagePattern, (m) => m[1]!)
      .replaceAllMapped(_linkPattern, (m) => m[1]!)
      .replaceAllMapped(_inlineCodePattern, (m) => m[1]!)
      .replaceAllMapped(_boldPattern, (m) => m[2]!)
      .replaceAllMapped(_italicPattern, (m) => m[1]!)
      .replaceAllMapped(_strikePattern, (m) => m[1]!)
      .replaceAll(_htmlTagPattern, '')
      .replaceAll(_whitespacePattern, ' ')
      .trim();
  if (text.length > _maxLabelLength) {
    text = '${text.substring(0, _maxLabelLength - 1)}…';
  }
  return text;
}

/// One chunk of a message that may mix prose with ```springtree fences:
/// either [markdown] prose or a springtree [treeSource] body.
class SpringTreeSegment {
  const SpringTreeSegment.markdown(this.markdown)
    : treeSource = null,
      treeComplete = true;

  const SpringTreeSegment.tree(this.treeSource, {required this.treeComplete})
    : markdown = null;

  /// Prose to render with the regular Markdown pipeline.
  final String? markdown;

  /// Body of a ```springtree fence, to render as a mind map.
  final String? treeSource;

  /// Whether the closing fence has been received yet (streaming).
  final bool treeComplete;

  bool get isTree => treeSource != null;
}

final RegExp _springTreeOpenFence = RegExp(
  r'```[ \t]*springtree[^\n]*(?:\n|$)',
  caseSensitive: false,
);
final RegExp _springTreeCloseFence = RegExp('\n[ \t]*```[^\n]*(?:\n|\$)');

/// Splits [content] into prose and springtree segments, so a chat message
/// can render the mind map at full width while the surrounding prose (and
/// any regular code blocks inside it) stays in the reading column. An
/// unclosed trailing fence yields a segment with `treeComplete: false`,
/// which keeps streaming growth working.
List<SpringTreeSegment> splitSpringTreeSegments(String content) {
  final segments = <SpringTreeSegment>[];
  var cursor = 0;
  while (true) {
    final open = _springTreeOpenFence.firstMatch(content.substring(cursor));
    if (open == null) {
      break;
    }
    final prose = content.substring(cursor, cursor + open.start);
    if (prose.trim().isNotEmpty) {
      segments.add(SpringTreeSegment.markdown(prose));
    }
    final bodyStart = cursor + open.end;
    final close = _springTreeCloseFence.firstMatch(
      content.substring(bodyStart),
    );
    if (close == null) {
      segments.add(
        SpringTreeSegment.tree(
          content.substring(bodyStart),
          treeComplete: false,
        ),
      );
      return segments;
    }
    segments.add(
      SpringTreeSegment.tree(
        content.substring(bodyStart, bodyStart + close.start),
        treeComplete: true,
      ),
    );
    cursor = bodyStart + close.end;
  }
  final tail = content.substring(cursor);
  if (tail.trim().isNotEmpty) {
    segments.add(SpringTreeSegment.markdown(tail));
  }
  if (segments.isEmpty) {
    segments.add(SpringTreeSegment.markdown(content));
  }
  return segments;
}
