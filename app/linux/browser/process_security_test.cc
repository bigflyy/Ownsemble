#include <cassert>
#include <filesystem>
#include <fstream>
#include <unistd.h>
#include "linux_process_security.h"
void Write(const std::filesystem::path& path, const std::string& text) {
  std::filesystem::create_directories(path.parent_path());
  std::ofstream(path) << text;
}
int main() {
  const auto root = std::filesystem::temp_directory_path() /
                    ("ownsemble-generated-proc-" + std::to_string(getpid()));
  Write(root / "100/task/100/children", "101 102");
  Write(root / "101/task/101/children", "201");
  Write(root / "102/task/102/children", "");
  Write(root / "201/task/201/children", "");
  Write(root / "101/status", "NSpid:\t101\t1\nSeccomp:\t0\n");
  Write(root / "102/status", "NSpid:\t102\nSeccomp:\t0\n");
  Write(root / "201/status", "NSpid:\t201\t2\nSeccomp:\t2\n");
  // An unrelated process must neither attest nor invalidate this browser.
  Write(root / "999/status", "NSpid:\t999\t2\nSeccomp:\t0\n");
  assert(RendererHasSeccomp(100, 2, root));
  assert(!RendererHasSeccomp(100, 3, root));
  Write(root / "201/status", "NSpid:\t201\t2\nSeccomp:\t0\n");
  assert(!RendererHasSeccomp(100, 2, root));
  Write(root / "999/status", "NSpid:\t999\t2\nSeccomp:\t2\n");
  assert(!RendererHasSeccomp(100, 2, root));
  // Cleanup is restricted to this newly generated, explicitly named fixture.
  std::filesystem::remove_all(root);
}
