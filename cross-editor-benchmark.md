
# Cross-Editor Benchmark Document

A GFM-only markdown file for fair cross-editor performance comparison.
No editor-specific extensions, no mermaid, no LaTeX math — only features every editor supports.

## Table of Contents

- [Heading Hierarchy](#heading-hierarchy)
- [Inline Formatting](#inline-formatting)
- [Bullet Lists](#bullet-lists)
- [Ordered Lists](#ordered-lists)
- [Task Lists](#task-lists)
- [Code Blocks](#code-blocks)
- [Tables](#tables)
- [Blockquotes](#blockquotes)
- [Horizontal Rules](#horizontal-rules)
- [Links and References](#links-and-references)
- [Images](#images)
- [Dense Paragraphs](#dense-paragraphs)

## Heading Hierarchy

### H3 — Section Level

#### H4 — Subsection

##### H5 — Minor Heading

###### H6 — Smallest Heading

### Another H3

#### With Nested H4

##### And H5

###### And H6

### Third H3 Section

Some body text under this heading to give it weight.

#### Sub-section A

Content for sub-section A.

#### Sub-section B

Content for sub-section B.

##### Deep Sub-section B1

Even deeper content here.

## Inline Formatting

This is **bold text** in a sentence. This is *italic text* in a sentence. This is ~~strikethrough text~~ in a sentence. This is `inline code` in a sentence.

Combined: **bold and *bold italic* together**. More: ~~strikethrough with **bold inside~~**. And: *italic with *`code inside`* too*.

A line with **multiple** bold **words** and *multiple* italic *words* and `multiple` code `spans` mixed together for density.

***Bold italic text*** stands alone. **~~Bold strikethrough~~** stands alone. *~~Italic strikethrough~~* stands alone.

Here is text with **bold at start** and text with **bold at end**. Here is text with *italic at start* and text with *italic at end*. Here is `code at start` text and text `code at end`.

Nesting test: **bold *italic inside bold* back to bold**. And *italic **bold inside italic** back to italic*. Deep: **bold *italic ~~strike~~ italic* bold**.

Repeated inline: **a** **b** **c** **d** **e** *a* *b* *c* *d* *e* `a` `b` `c` `d` `e` ~~a~~ ~~b~~ ~~c~~ ~~d~~ ~~e~~.

Long bold paragraph: **This entire paragraph is bold. It contains multiple sentences to test how editors handle long runs of bold text. The formatting should be consistent from start to finish without any visual glitches or rendering artifacts.**

Long italic paragraph: *This entire paragraph is italic. It also spans multiple sentences to verify that italic rendering remains stable over longer text runs. No breaks or flickers should appear.*

Long code span: `This is a longer inline code span that contains spaces, punctuation (commas, periods, semicolons;), and even some "quoted text" inside it`.

## Bullet Lists

- Simple item one
- Simple item two
- Simple item three

- First level
  - Second level
    - Third level
      - Fourth level
    - Back to third
  - Back to second
- Back to first

- Item with **bold text**
- Item with *italic text*
- Item with `inline code`
- Item with ~~strikethrough~~
- Item with [a link](https://example.com)

- Paragraph item one. This item has enough text to potentially wrap to a second line in most editor windows.

- Paragraph item two. Similarly, this item contains a reasonable amount of text that exercises line wrapping within a list item.

- Paragraph item three. And a third for good measure, ensuring the list renderer handles multiple wrapped items.

- Mixed content list:
  - Nested with **bold**
  - Nested with *italic*
    - Deep nested with `code`
    - Deep nested with ~~strike~~
  - Back to second level

- Alpha list
  - Beta item
  - Gamma item
    - Delta item
    - Epsilon item
      - Zeta item
      - Eta item
    - Theta item
  - Iota item
- Kappa list end

## Ordered Lists

1. First ordered item
2. Second ordered item
3. Third ordered item

1. Top level one
   1. Sub-item one-one
   2. Sub-item one-two
      1. Sub-sub one-two-one
      2. Sub-sub one-two-two
   3. Sub-item one-three
2. Top level two
   1. Sub-item two-one
   2. Sub-item two-two
3. Top level three

1. Item with **bold text**
2. Item with *italic text*
3. Item with `inline code`
4. Item with ~~strikethrough~~
5. Item with [a link](https://example.com)

1. First ordered paragraph item. This contains enough text to verify that ordered list rendering handles wrapped lines correctly, with the number aligned properly.

2. Second ordered paragraph item. The continuation indent should line up with the start of text on the first line, not with the number.

3. Third ordered paragraph item. Testing that the third item in sequence renders with consistent spacing and alignment.

## Task Lists

- [ ] Unchecked task one
- [x] Checked task one
- [ ] Unchecked task two
- [x] Checked task two
- [ ] Unchecked task three

- [ ] Task with **bold description**
- [x] Completed task with ~~strikethrough description~~
- [ ] Task with `code in description`
- [x] Done: *italic description here*

- [ ] Parent task
  - [ ] Child task one
  - [x] Child task two (done)
  - [ ] Child task three
    - [ ] Grandchild task
    - [x] Grandchild done
  - [ ] Child task four

- [x] Design the feature
- [x] Write the implementation
- [ ] Add unit tests
- [ ] Write documentation
- [ ] Review and merge

1. [ ] Ordered unchecked task
2. [x] Ordered checked task
3. [ ] Ordered unchecked task two
4. [x] Ordered checked task two

## Code Blocks

```javascript
function fibonacci(n) {
  if (n <= 1) return n;
  let a = 0, b = 1;
  for (let i = 2; i <= n; i++) {
    [a, b] = [b, a + b];
  }
  return b;
}

console.log(`Fibonacci(10) = ${fibonacci(10)}`);

const result = Array.from({ length: 20 }, (_, i) => fibonacci(i));
console.log('First 20:', result.join(', '));
```

```python
from typing import Generator

def fibonacci_gen() -> Generator[int, None, None]:
    a, b = 0, 1
    while True:
        yield a
        a, b = b, a + b

def take(n: int, gen: Generator) -> list:
    return [next(gen) for _ in range(n)]

gen = fibonacci_gen()
print(f"First 20 Fibonacci: {take(20, gen)}")

# Dictionary comprehension
squares = {x: x**2 for x in range(1, 11)}
print(f"Squares: {squares}")
```

```swift
struct Stack<Element> {
    private var storage: [Element] = []

    mutating func push(_ element: Element) {
        storage.append(element)
    }

    mutating func pop() -> Element? {
        storage.popLast()
    }

    var peek: Element? { storage.last }
    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }
}

var stack = Stack<Int>()
stack.push(1)
stack.push(2)
stack.push(3)
print("Top: \(stack.peek ?? 0)")
```

```rust
use std::collections::HashMap;

fn word_count(text: &str) -> HashMap<&str, usize> {
    let mut counts = HashMap::new();
    for word in text.split_whitespace() {
        *counts.entry(word).or_insert(0) += 1;
    }
    counts
}

fn main() {
    let text = "the quick brown fox jumps over the lazy dog the fox";
    let counts = word_count(text);
    for (word, count) in &counts {
        println!("{word}: {count}");
    }
}
```

```go
package main

import (
    "fmt"
    "strings"
    "sync"
)

func wordCount(text string) map[string]int {
    counts := make(map[string]int)
    var mu sync.Mutex
    words := strings.Fields(text)

    var wg sync.WaitGroup
    for _, word := range words {
        wg.Add(1)
        go func(w string) {
            defer wg.Done()
            mu.Lock()
            counts[w]++
            mu.Unlock()
        }(word)
    }
    wg.Wait()
    return counts
}

func main() {
    text := "hello world hello go world"
    fmt.Println(wordCount(text))
}
```

```bash
#!/bin/bash
set -euo pipefail

count_files() {
    local dir="${1:-.}"
    local ext="${2:-*}"
    find "$dir" -name "*.${ext}" -type f | wc -l | tr -d ' '
}

echo "Swift files: $(count_files src swift)"
echo "Test files: $(count_files tests swift)"

for f in *.md; do
    lines=$(wc -l < "$f" | tr -d ' ')
    words=$(wc -w < "$f" | tr -d ' ')
    printf "%-30s %6d lines %8d words\n" "$f" "$lines" "$words"
done
```

```json
{
  "name": "acme-utils",
  "version": "2.4.1",
  "description": "General-purpose utility library for data transformation",
  "license": "MIT",
  "main": "dist/index.js",
  "scripts": {
    "build": "tsc --project tsconfig.json",
    "test": "jest --coverage --verbose",
    "lint": "eslint src/ --ext .ts",
    "bench": "node benchmarks/run.js"
  },
  "dependencies": {
    "lodash": "^4.17.21",
    "dayjs": "^1.11.10"
  },
  "devDependencies": {
    "typescript": "^5.3.0",
    "jest": "^29.7.0",
    "eslint": "^8.56.0"
  }
}
```

```yaml
name: CI Pipeline
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node-version: [18, 20, 22]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}
          cache: npm
      - run: npm ci
      - run: npm test
      - run: npm run lint

  build:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
      - run: npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/
```

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Recipe: Classic Margherita Pizza</title>
    <style>
        body { font-family: Georgia, serif; max-width: 720px; margin: 2rem auto; line-height: 1.6; }
        h1 { border-bottom: 2px solid #c0392b; padding-bottom: 0.5rem; }
        .meta { color: #666; font-style: italic; }
        .ingredients li { margin: 0.25rem 0; }
        .step { margin: 1rem 0; padding-left: 1rem; border-left: 3px solid #e74c3c; }
    </style>
</head>
<body>
    <h1>Classic Margherita Pizza</h1>
    <p class="meta">Prep: 20 min | Cook: 12 min | Serves: 4</p>
    <h2>Ingredients</h2>
    <ul class="ingredients">
        <li>500g bread flour</li>
        <li>7g active dry yeast</li>
        <li>1 tsp salt</li>
        <li>325ml warm water</li>
        <li>400g San Marzano tomatoes, crushed</li>
        <li>250g fresh mozzarella, sliced</li>
        <li>Fresh basil leaves</li>
        <li>Extra-virgin olive oil</li>
    </ul>
    <h2>Instructions</h2>
    <div class="step"><strong>1.</strong> Mix flour, yeast, and salt. Add water and knead 10 minutes.</div>
    <div class="step"><strong>2.</strong> Let dough rise 1 hour, covered, until doubled in size.</div>
    <div class="step"><strong>3.</strong> Preheat oven to 260°C (500°F) with a pizza stone.</div>
    <div class="step"><strong>4.</strong> Stretch dough into a 30cm circle. Add sauce, mozzarella, basil.</div>
    <div class="step"><strong>5.</strong> Bake 10–12 minutes until crust is golden and cheese bubbles.</div>
</body>
</html>
```

```css
:root {
    --color-primary: #2563eb;
    --color-success: #16a34a;
    --color-warning: #d97706;
    --color-error: #dc2626;
    --font-mono: 'SF Mono', 'Fira Code', monospace;
}

.dashboard-card {
    display: grid;
    grid-template-columns: 1fr 1fr 1fr;
    gap: 1rem;
    padding: 1.5rem;
    border-radius: 0.5rem;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
}

.metric {
    font-family: var(--font-mono);
    font-size: 2rem;
    font-weight: 700;
}

.metric.positive { color: var(--color-success); }
.metric.negative { color: var(--color-error); }

@media (max-width: 640px) {
    .dashboard-card {
        grid-template-columns: 1fr;
    }
}
```

## Tables

| Language | Paradigm | Type System | First Released | Notable Feature |
| --- | --- | --- | --- | --- |
| Python | Multi-paradigm | Dynamic, strong | 1991 | Indentation-based scoping |
| Rust | Multi-paradigm | Static, strong | 2015 | Ownership and borrowing |
| Swift | Multi-paradigm | Static, strong | 2014 | Protocol-oriented design |
| Go | Concurrent, imperative | Static, strong | 2009 | Goroutines and channels |
| TypeScript | Multi-paradigm | Static, structural | 2012 | Gradual typing over JS |

| Task | Assignee | Status | Due Date | Priority |
| --- | --- | --- | --- | --- |
| Set up CI pipeline | Alex | Done | 2026-01-15 | P0 |
| Write API documentation | Jordan | In Progress | 2026-02-01 | P1 |
| Add integration tests | Sam | Planned | 2026-02-15 | P1 |
| Performance profiling | Casey | Backlog | 2026-03-01 | P2 |
| Dependency audit | Morgan | Backlog | 2026-03-15 | P2 |

| Metric | Formula | Description |
| --- | --- | --- |
| Median | Middle value of sorted runs | Primary comparison number |
| Mean | Sum / count | Secondary metric |
| Std Dev | sqrt(variance) | Consistency measure |
| CV% | (std / mean) * 100 | Below 10% is reliable |
| IQR | Q3 - Q1 | Spread of middle 50% |

| Column | Type | Nullable | Default | Description |
| --- | --- | --- | --- | --- |
| id | BIGINT | No | auto | Primary key |
| name | VARCHAR(255) | No | — | Display name |
| email | VARCHAR(320) | No | — | Unique, indexed |
| created_at | TIMESTAMP | No | now() | Row creation time |
| updated_at | TIMESTAMP | Yes | NULL | Last modification |

| Left Aligned | Center Aligned | Right Aligned |
| :--- | :---: | ---: |
| Row 1 Col 1 | Row 1 Col 2 | Row 1 Col 3 |
| Row 2 Col 1 | Row 2 Col 2 | Row 2 Col 3 |
| Row 3 Col 1 | Row 3 Col 2 | Row 3 Col 3 |
| Longer text in this cell | Short | 12345 |
| A | Medium length text | 67890 |

## Blockquotes

> Simple single-line blockquote.

> Multi-line blockquote that spans across more than one line. This tests how the editor handles longer quoted text that may wrap within the blockquote container.

> First paragraph in blockquote.
>
> Second paragraph in the same blockquote, separated by a blank quoted line.

> Blockquote with **bold**, *italic*, `code`, and ~~strikethrough~~ formatting.

> Level one quote.
>
> > Level two nested quote.
> >
> > > Level three deeply nested quote.
> >
> > Back to level two.
>
> Back to level one.

> Blockquote with a list:
>
> - Item one
> - Item two
> - Item three

> "The best way to predict the future is to invent it." — Alan Kay

> "Premature optimization is the root of all evil." — Donald Knuth

> "Any sufficiently advanced technology is indistinguishable from magic." — Arthur C. Clarke

## Horizontal Rules

Content above the first rule.

---

Content between rules.

***

More content between rules.

___

Content after the last rule.

---

## Links and References

Inline links: [GitHub](https://github.com), [Example](https://example.com), [Google](https://google.com).

Link with title: [Markdown Guide](https://www.markdownguide.org "The Markdown Guide").

Autolinks: <https://example.com>, <https://github.com/user/repo>.

Multiple links in one line: Visit [Site A](https://example.com/a) then [Site B](https://example.com/b) and finally [Site C](https://example.com/c).

Link in **bold**: [**Bold Link**](https://example.com). Link in *italic*: [*Italic Link*](https://example.com). Link in `code`: `code link`.

Long URL link: [Documentation with very long path](https://example.com/docs/api/v2/reference/endpoints/users/permissions/list?page=1&limit=100&sort=created_at&order=desc).

Reference-style links work well in longer documents. The [Rust Book][rust-book] is a
comprehensive resource, as is the [Go Tour][go-tour]. For web standards, see the
[MDN Web Docs][mdn] or the [WHATWG HTML Spec][whatwg].

[rust-book]: https://doc.rust-lang.org/book/
[go-tour]: https://go.dev/tour/
[mdn]: https://developer.mozilla.org/
[whatwg]: https://html.spec.whatwg.org/

## Images

Local image (relative path):

![Test card](benchmark-test-image.png)

## Dense Paragraphs

Performance testing requires paragraphs with varied sentence length and structure. Short sentences test basic rendering. Longer sentences with multiple clauses, subordinate phrases, and parenthetical asides (like this one) test the text layout engine's ability to handle complex line breaking and word wrapping across the full width of the editor window.

The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump. The five boxing wizards jump quickly. Sphinx of black quartz, judge my vow. Two driven jocks help fax my big quiz.

Formatting within paragraphs is common in real documents: users write **important terms** in bold, *emphasize key phrases* in italic, reference `variable names` and `function calls` in code, and occasionally ~~cross things out~~ when editing. A well-performing editor handles this without flicker or delay.

Numbers and data appear frequently: version 3.14.159, release date 2026-02-18, file size 3,686,400 bytes, response time 142ms over 30 iterations with CV% of 6.8%. Editors must render these without special treatment.

Unicode and special characters: em dash — en dash – ellipsis… smart quotes "hello" and 'world'. Copyright ©2026. Trademark™. Registered®. Arrows: → ← ↑ ↓. Bullets: • ◦ ▪. Currency: $100 €95 £80 ¥12000.

Technical writing: The `O(n log n)` algorithm outperforms the naive `O(n²)` approach for inputs larger than ~1000 elements. Memory usage scales linearly at approximately 80MB baseline plus 0.5MB per 1000 lines. The p95 latency stays under 16ms (one frame at 60fps) for documents under 50K characters.

Mixed formatting density: In this paragraph, **every** *other* `word` ~~has~~ **some** *kind* `of` ~~inline~~ **formatting** *applied* `to` ~~it~~ **for** *maximum* `rendering` ~~stress~~ **testing** *purposes*.

A paragraph with a single very long word that should not break the layout: Supercalifragilisticexpialidocious. And a long technical identifier: `NativeEditorViewControllerMegaStressPerformanceTestCaseWithLongMethodName`.

Typography is the art and technique of arranging type to make written language legible, readable, and appealing when displayed. The arrangement of type involves selecting typefaces, point sizes, line lengths, line-spacing (leading), letter-spacing (tracking), and adjusting the space between pairs of letters. The term typography is also applied to the style, arrangement, and appearance of the letters, numbers, and symbols created by the process.

Color theory encompasses a multitude of definitions, concepts, and design applications. The color wheel, color harmony, and the context of how colors are used are among the core principles. Colors can evoke emotional responses — warm reds and oranges create energy, cool blues and greens inspire calm, and neutral tones provide balance. Understanding complementary, analogous, and triadic color schemes allows designers to create visually coherent interfaces.

Software engineering is the systematic application of engineering approaches to the development of software. A software engineer applies the engineering design process to design, develop, test, maintain, and evaluate computer software. The discipline differs from simple programming in that it applies formal methods and best practices to large-scale, long-lived systems. Key concerns include requirements analysis, architectural design, coding standards, testing strategies, and deployment pipelines.

The principles of good API design emphasize consistency, predictability, and minimal surprise. Every endpoint should follow the same naming conventions, error formats, and authentication patterns. Pagination should work identically whether you are listing users, orders, or products. Rate limits should be communicated through standard headers rather than custom error codes.

A well-structured codebase separates concerns clearly: data access logic stays in repositories, business rules live in services, and presentation logic remains in controllers or views. This separation makes each layer independently testable and replaceable. When a database migration changes a column name, only the repository layer needs updating — the service and presentation layers remain untouched.

This line has two trailing spaces at the end for a hard break.
This line continues after the hard break, testing GFM hard line break rendering.
A third line after another hard break, verifying consistent behavior.

## Closing

This file contains approximately 580 lines of pure GFM markdown covering headings, inline formatting, bullet lists, ordered lists, task lists, code blocks in 10 languages, tables with alignment variants, blockquotes with nesting, horizontal rules, inline and reference-style links, images, hard line breaks, and dense paragraphs. Every feature tested is part of the GitHub Flavored Markdown specification and supported by all major editors.
