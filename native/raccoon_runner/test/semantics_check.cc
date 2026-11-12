// raccoon_semantics_check: the semantics tree the runner keeps for clients
// that ask. Updates merge by node id, nodes no longer under the root go,
// and each node's bounds come out in the view with every transform above
// it applied: the root's pixel ratio, a scroll offset, a scale, a frame
// scaled down to fit. Prints one line; exits 0 on a pass. Run by the
// runtime's integration tests; not shipped.
#include <cmath>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "semantics_tree.h"

using raccoon::SemanticsTree;

namespace {

int Fail(const std::string& why) {
  std::printf("SEMANTICS failed: %s\n", why.c_str());
  return 1;
}

SemanticsTree::Node NodeOf(int32_t id, std::array<double, 4> rect,
                           SemanticsTree::Transform transform,
                           std::vector<int32_t> children = {}, std::string label = "") {
  SemanticsTree::Node node;
  node.id = id;
  node.rect = rect;
  node.transform = transform;
  node.children = std::move(children);
  node.label = std::move(label);
  return node;
}

SemanticsTree::Transform Translate(double x, double y) { return {1, 0, x, 0, 1, y, 0, 0, 1}; }
SemanticsTree::Transform Scale(double by) { return {by, 0, 0, 0, by, 0, 0, 0, 1}; }

bool Near(double a, double b) { return std::abs(a - b) < 1e-6; }

// The node of |id| as placed, or null.
const SemanticsTree::Placed* Find(const std::vector<SemanticsTree::Placed>& placed, int32_t id) {
  for (const SemanticsTree::Placed& node : placed) {
    if (node.node->id == id) return &node;
  }
  return nullptr;
}

bool At(const SemanticsTree::Placed* node, double left, double top, double right,
        double bottom) {
  return node != nullptr && Near(node->left, left) && Near(node->top, top) &&
         Near(node->right, right) && Near(node->bottom, bottom);
}

}  // namespace

int main() {
  SemanticsTree tree;
  if (tree.has_root() || !tree.Flatten().empty()) return Fail("an empty tree has nodes");

  // The root scales logical pixels to physical ones at a ratio of 2, as
  // RenderView's does; a list scrolled by 30 holds two buttons, the second
  // drawn at half its size.
  std::vector<SemanticsTree::Node> first;
  first.push_back(NodeOf(0, {0, 0, 400, 300}, Scale(2), {1}));
  first.push_back(NodeOf(1, {0, 0, 400, 300}, SemanticsTree::kIdentity, {2, 3}));
  first.push_back(NodeOf(2, {0, 0, 100, 40}, Translate(10, 50 - 30), {}, "Save"));
  first.push_back(NodeOf(3, {0, 0, 100, 40},
                         SemanticsTree::Multiply(Translate(10, 100), Scale(0.5)), {}, "Undo"));
  tree.Apply(first);
  if (!tree.has_root()) return Fail("the root did not arrive");

  std::vector<SemanticsTree::Placed> placed = tree.Flatten();
  if (placed.size() != 4) return Fail("expected 4 nodes, got " + std::to_string(placed.size()));
  if (placed[0].node->id != 0 || placed[1].node->id != 1 || placed[2].node->id != 2 ||
      placed[3].node->id != 3) {
    return Fail("nodes not in traversal order");
  }
  if (!At(Find(placed, 0), 0, 0, 800, 600)) return Fail("the root is not the view");
  if (!At(Find(placed, 2), 20, 40, 220, 120)) return Fail("Save is misplaced");
  if (!At(Find(placed, 3), 20, 200, 120, 240)) return Fail("Undo is misplaced");

  // A frame scaled down to fit by a half: the client sized the view twice
  // as large, and its pixels are what the nodes come out in.
  placed = tree.Flatten(0.5);
  if (!At(Find(placed, 2), 40, 80, 440, 240)) return Fail("the fit scale is not undone");

  // An update names only what changed: Save's label, and the list now
  // without Undo, which goes.
  std::vector<SemanticsTree::Node> second;
  second.push_back(NodeOf(1, {0, 0, 400, 300}, SemanticsTree::kIdentity, {2}));
  second.push_back(NodeOf(2, {0, 0, 100, 40}, Translate(10, 20), {}, "Saved"));
  tree.Apply(second);
  placed = tree.Flatten();
  if (placed.size() != 3 || Find(placed, 3) != nullptr) return Fail("Undo stayed");
  if (Find(placed, 2)->node->label != "Saved") return Fail("Save's label was not merged");
  if (tree.size() != 3) return Fail("a removed node is still kept");

  // A rotation a quarter turn: the bounds are the box around the corners.
  SemanticsTree turned;
  std::vector<SemanticsTree::Node> rotated;
  rotated.push_back(NodeOf(0, {0, 0, 100, 100}, SemanticsTree::kIdentity, {1}));
  rotated.push_back(NodeOf(1, {0, 0, 40, 20}, {0, -1, 50, 1, 0, 10, 0, 0, 1}));
  turned.Apply(rotated);
  if (!At(Find(turned.Flatten(), 1), 30, 10, 50, 50)) return Fail("rotated bounds are wrong");

  // A cycle a broken update could make reads each node once.
  SemanticsTree cyclic;
  std::vector<SemanticsTree::Node> loop;
  loop.push_back(NodeOf(0, {0, 0, 10, 10}, SemanticsTree::kIdentity, {1}));
  loop.push_back(NodeOf(1, {0, 0, 10, 10}, SemanticsTree::kIdentity, {0, 1}));
  cyclic.Apply(loop);
  if (cyclic.Flatten().size() != 2) return Fail("a cycle was read more than once");

  std::printf("SEMANTICS ok\n");
  return 0;
}
