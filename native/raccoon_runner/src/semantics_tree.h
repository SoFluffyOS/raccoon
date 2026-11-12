#pragma once

// One view's semantics tree as the engine sends it: a whole tree when
// semantics turn on, then the nodes that changed. Kept here by node id, and
// read out with each node's bounds in the view, every transform above it
// applied. No embedder types, so its check builds without an engine.

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace raccoon {

class SemanticsTree {
 public:
  // A 3x3 transform, row by row as FlutterTransformation has it: scale x,
  // skew x, translate x; skew y, scale y, translate y; perspective 0, 1, 2.
  using Transform = std::array<double, 9>;
  static constexpr Transform kIdentity = {1, 0, 0, 0, 1, 0, 0, 0, 1};

  struct Node {
    int32_t id = 0;
    std::string label;
    std::string value;
    std::string hint;
    std::string tooltip;
    std::string identifier;
    // Flutter's SemanticsFlag and SemanticsAction bits.
    uint64_t flags = 0;
    uint64_t actions = 0;
    // Left, top, right, bottom in the node's own coordinates.
    std::array<double, 4> rect = {0, 0, 0, 0};
    // From the node's coordinates to its parent's.
    Transform transform = kIdentity;
    std::vector<int32_t> children;
  };

  // A node read out: its bounds in the view, in the client's pixels.
  struct Placed {
    const Node* node;
    double left, top, right, bottom;
  };

  // Takes an update: each node replaces the one of its id. Nodes no longer
  // under the root go.
  void Apply(std::vector<Node> nodes);
  void Clear() { nodes_.clear(); }
  // Whether the root (id 0) arrived: before it there is no tree to read.
  bool has_root() const { return nodes_.count(0) != 0; }
  size_t size() const { return nodes_.size(); }

  // Every node under the root in traversal order, the root first. Bounds
  // are divided by |input_scale|, what the view's frame was scaled by to fit
  // (#117), so they come out in the pixels the client sized the view in.
  std::vector<Placed> Flatten(double input_scale = 1.0) const;

  static Transform Multiply(const Transform& a, const Transform& b);

 private:
  std::unordered_map<int32_t, Node> nodes_;
};

}  // namespace raccoon
