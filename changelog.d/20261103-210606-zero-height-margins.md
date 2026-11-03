type: Fixed

**Margins collapse through an empty box of `height: 0`** as they do through one of `height: auto` (CSS 2 §8.3.1): a clearfix of zero height between a paragraph and a heading (Google's AI mode answers) added its neighbours' margins instead of keeping the larger.
