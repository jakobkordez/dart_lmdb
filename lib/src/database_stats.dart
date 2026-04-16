import 'dart:math';

/// Represents statistical information about an LMDB database.
///
/// This class provides detailed metrics about the database structure,
/// including page allocation and B+ tree characteristics.
class DatabaseStats {
  /// Size of a database page in bytes.
  ///
  /// This is typically a multiple of the system's page size
  /// (usually 4096 bytes on most systems).
  final int pageSize;

  /// Depth of the B+ tree.
  ///
  /// Indicates how many levels of pages must be traversed
  /// to reach any leaf page from the root.
  final int depth;

  /// Number of branch pages in the B+ tree.
  ///
  /// Branch pages contain only keys and pointers to other pages,
  /// forming the internal nodes of the tree.
  final int branchPages;

  /// Number of leaf pages in the B+ tree.
  ///
  /// Leaf pages contain the actual key-value pairs
  /// stored in the database.
  final int leafPages;

  /// Number of overflow pages.
  ///
  /// Overflow pages are used when values are too large
  /// to fit in a regular leaf page.
  final int overflowPages;

  /// Total number of entries (key-value pairs) in the database.
  final int entries;

  /// Creates a new DatabaseStats instance.
  ///
  /// Example:
  /// ```dart
  /// final stats = DatabaseStats(
  ///   pageSize: 4096,
  ///   depth: 3,
  ///   branchPages: 10,
  ///   leafPages: 100,
  ///   overflowPages: 0,
  ///   entries: 1000,
  /// );
  /// ```
  DatabaseStats({
    required this.pageSize,
    required this.depth,
    required this.branchPages,
    required this.leafPages,
    required this.overflowPages,
    required this.entries,
  });

  /// Returns a string representation of the database statistics.
  ///
  /// Useful for logging and debugging purposes.
  ///
  /// Example:
  /// ```dart
  /// final stats = await db.getStats();
  /// print(stats.toString());
  /// // Prints: DatabaseStats(pageSize: 4096, depth: 3, ...)
  /// ```
  @override
  String toString() {
    return 'DatabaseStats('
        'pageSize: $pageSize, '
        'depth: $depth, '
        'branchPages: $branchPages, '
        'leafPages: $leafPages, '
        'overflowPages: $overflowPages, '
        'entries: $entries)';
  }

  /// Analyzes current database usage and returns a formatted string report.
  ///
  /// The report includes information about:
  /// * Total number of entries
  /// * Tree structure details
  /// * Performance metrics
  ///
  /// Example:
  /// ```dart
  /// final stats = await db.getStats();
  /// print(LMDBConfig.analyzeUsage(stats));
  /// ```
  String analyzeUsage() {
    final branchToLeafRatio = leafPages > 0 ? branchPages / leafPages : 0.0;
    final averageEntriesPerLeafPage = leafPages > 0 ? entries / leafPages : 0.0;

    return '''
Database Usage Analysis:
- Total Entries: $entries
- Tree Structure:
  • Depth: $depth
  • Branch Pages: $branchPages
  • Leaf Pages: $leafPages
  • Branch/Leaf Ratio: ${branchToLeafRatio.toStringAsFixed(3)}
- Performance Metrics:
  • Average Entries per Leaf Page: ${averageEntriesPerLeafPage.toStringAsFixed(2)}
  • Overflow Pages: $overflowPages
''';
  }

  //// Analyzes database efficiency and returns structured metrics.
  ///
  /// Returns a [DatabaseEfficiency] object containing various
  /// performance and structure metrics.
  ///
  /// Example:
  /// ```dart
  /// final stats = await db.getStats();
  /// final efficiency = LMDBConfig.analyzeEfficiency(stats);
  /// if (!efficiency.isWellBalanced) {
  ///   print('Database structure needs optimization');
  /// }
  /// ```
  DatabaseEfficiency analyzeEfficiency() {
    return DatabaseEfficiency(
      totalEntries: entries,
      treeDepth: depth,
      branchToLeafRatio: leafPages > 0 ? branchPages / leafPages : 0.0,
      averageEntriesPerLeafPage: leafPages > 0 ? entries / leafPages : 0.0,
      hasOverflow: overflowPages > 0,
    );
  }
}

/// Represents database efficiency metrics for analyzing LMDB performance.
///
/// This class provides structured access to various database metrics
/// and helper methods to evaluate database health.
class DatabaseEfficiency {
  /// Total number of entries in the database
  final int totalEntries;

  /// Depth of the B+ tree
  final int treeDepth;

  /// Ratio of branch pages to leaf pages
  final double branchToLeafRatio;

  /// Average number of entries stored per leaf page
  final double averageEntriesPerLeafPage;

  /// Indicates if the database has overflow pages
  final bool hasOverflow;

  /// Creates a new DatabaseEfficiency instance
  DatabaseEfficiency({
    required this.totalEntries,
    required this.treeDepth,
    required this.branchToLeafRatio,
    required this.averageEntriesPerLeafPage,
    required this.hasOverflow,
  });

  /// Returns true if the B+ tree structure is well-balanced.
  ///
  /// A well-balanced tree has:
  /// * Branch to leaf ratio < 0.3 (fewer branch pages than leaf pages)
  /// * Tree depth close to optimal for the number of entries
  bool get isWellBalanced =>
      branchToLeafRatio < 0.3 &&
      treeDepth <= (log(totalEntries) / log(2)).ceil();

  /// Returns true if the database storage is efficiently utilized.
  ///
  /// Efficient storage has:
  /// * Good number of entries per leaf page (>10)
  /// * No overflow pages
  bool get isEfficient => averageEntriesPerLeafPage > 10 && !hasOverflow;
}
