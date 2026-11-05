import 'package:ownsemble/library/file_print.dart';
import 'package:ownsemble/library/library_store.dart';

/// One made-up VK file, given to every row [mergeSameFiles] prints.
const sameFile = FilePrint(bytes: 4000000, sample: 1, seconds: 200);

/// Merges [store]'s accounts as if VK gave every candidate row the same
/// file (what the sync reads in real use, Stage L), so the candidate rule
/// alone decides.
MergeResult mergeSameFiles(LibraryStore store) {
  store.savePrints({
    for (final row in store.printsToRead()) row.trackId: sameFile,
  });
  return store.mergeSameSongs();
}
