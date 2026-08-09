# Markdown Rendering

The notebook editor saves Markdown source text, and the preview area renders the same source into a readable document. The editor and preview use the same current content; after saving, the content is written to the current daily, weekly, or monthly note file.

## Editor

The editor supports standard text input, undo, redo, clipboard paste, and image insertion. Markdown source is preserved as-is; the editor does not rewrite headings, lists, links, or emphasis symbols due to preview rendering.

Markdown syntax highlighting is an independent display feature. When enabled, it only changes the color of Markdown syntax tokens and symbols — it does not alter characters, font shapes, saved text, or preview results. When disabled, the editor displays plain text.

## Preview Content

The preview supports headings, paragraphs, lists, links, images, tables, code blocks, and mathematical formulas. Code blocks are styled according to their language tag, and mathematical formulas are rendered using LaTeX rules.

### SpringTree Mind Maps

A code block tagged `springtree` renders as a mind map instead of a regular code block. The format builds on the Markdown unordered list; it is primarily used for the Memory Book's "mind map" output mode, and can also be written by hand in any note.

#### Syntax

- Tag the code block with the language `springtree`.
- Each line is one node, starting with `-`.
- Indentation expresses hierarchy: more deeply indented nodes are children of the shallower node above them.
- Node text is plain text — letters, numbers, symbols; nested Markdown styling is not supported.
- Sibling nodes are laid out in their order of appearance.

#### Example

````markdown
```springtree
- Project Overview
  - Frontend
    - Finish login page
    - Speed up home page loading
  - Backend
    - Design user table
    - Integrate OAuth sign-in
  - Next Week
    - API integration testing
    - Add unit tests
```
````

This renders as a mind map centered on "Project Overview", expanding outward.

#### Interactions

A rendered mind map supports the following actions:

- **Pan**: drag on the canvas with the left mouse button, or drag on a touchscreen.
- **Zoom**: use the mouse wheel, or the zoom in/out buttons in the bottom-right corner; zoom is limited to 0.2×–3×.
- **Fit**: the fit button centers the canvas and zooms to show the whole map.
- **Fullscreen**: the fullscreen button opens the map in a fullscreen dialog; close it with the exit button or `Esc`.
- **Copy source**: the copy button in the map header copies the raw `springtree` text.

Node text is not selectable, so text selection cannot conflict with the pan gesture.

#### Grow Animation

- While content streams in (for example in Memory Book conversations), new nodes "grow" in one by one with a fade-and-scale animation.
- When a single update introduces more than 96 nodes at once — for example when opening a large, already-written map — that batch appears directly without the animation, to keep the interface smooth.

#### Node Limits

SpringTree maps have two levels of limits:

- **Parse limit**: any map keeps at most 300 nodes when parsed; extra lines are discarded. This applies to notes, the fullscreen view, and the Memory Book alike. Node text longer than 120 characters is truncated with an ellipsis.
- **Inline render limit**: to keep large maps fast to open and switch to, a note's inline view (preview, split panes) renders at most 120 nodes. Nodes are kept level-first: the root and shallow branches are shown first, and deeper branches beyond the limit are hidden as a whole. When a map is truncated, the header shows a "+N" badge, where N is the number of hidden nodes; hover over the badge for an explanation. The fullscreen button opens the complete map — the fullscreen view is not subject to the inline limit.

The Memory Book page has no inline render limit; maps in conversations render in full from the parse result (up to 300 nodes).

The preview area supports text selection and scrolling. Markdown links can be opened, and images are resolved relative to the note's directory and data directory references.

## Image References

Images inserted through the notebook are saved as Markdown image links; during preview, relative paths are resolved based on the current note's path. Deleting a Markdown image link only changes the body reference; it does not automatically delete the image file from the data directory. Image file cleanup is handled by the Storage Management page.

## Empty Content & Errors

When the current Markdown is empty, the preview area shows an empty state hint and does not generate fabricated content. When an image path is invalid, the link in the body is retained, but the preview cannot display the image. Unrecognized Markdown structures are displayed as parseable plain text or basic structures, and the original source is not deleted.
