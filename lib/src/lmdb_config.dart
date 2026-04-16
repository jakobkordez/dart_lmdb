/// Configuration and utility functions for LMDB (Lightning Memory-Mapped Database)
///
/// This class provides utilities for:
/// * Calculating optimal database sizes
/// * Analyzing database efficiency
/// * Managing database configurations
class LMDBConfig {
  /// Default overhead factor for B+ tree structure and future growth.
  /// A factor of 1.5 means 50% extra space is reserved for the B+ tree structure.
  static const double defaultOverheadFactor = 1.5;

  /// Minimum map size in bytes (1MB).
  /// The database cannot be smaller than this value.
  static const int minMapSize = 1 * 1024 * 1024;

  /// Calculates the maximum possible entries for a given map size.
  ///
  /// Use this to determine how many entries can fit in your database.
  ///
  /// Parameters:
  /// * [mapSize] - Total database size in bytes
  /// * [averageKeySize] - Expected average size of keys in bytes
  /// * [averageValueSize] - Expected average size of values in bytes
  /// * [overheadFactor] - Factor to account for B+ tree overhead (default: 1.5)
  ///
  /// Returns the estimated maximum number of entries that can be stored.
  ///
  /// Example:
  /// ```dart
  /// final maxEntries = LMDBConfig.calculateMaxEntries(
  ///   mapSize: 1024 * 1024 * 100, // 100MB
  ///   averageKeySize: 16,
  ///   averageValueSize: 64,
  /// );
  /// ```
  static int calculateMaxEntries({
    required int mapSize,
    required int averageKeySize,
    required int averageValueSize,
    double overheadFactor = defaultOverheadFactor,
  }) {
    // Calculate average entry size including overhead
    final entrySize = (averageKeySize + averageValueSize) * overheadFactor;

    // Calculate maximum entries, ensuring we don't exceed available space
    return (mapSize / entrySize).floor();
  }

  /// Calculates required map size based on expected data volume.
  ///
  /// Use this to determine the optimal database size for your needs.
  ///
  /// Parameters:
  /// * [expectedEntries] - Number of entries planned to store
  /// * [averageKeySize] - Expected average size of keys in bytes
  /// * [averageValueSize] - Expected average size of values in bytes
  /// * [overheadFactor] - Factor for B+ tree overhead (default: 1.5)
  ///
  /// Returns the recommended map size in bytes, never less than [minMapSize].
  ///
  /// Example:
  /// ```dart
  /// final mapSize = LMDBConfig.calculateMapSize(
  ///   expectedEntries: 1000000,
  ///   averageKeySize: 16,
  ///   averageValueSize: 64,
  /// );
  /// ```
  static int calculateMapSize({
    required int expectedEntries,
    required int averageKeySize,
    required int averageValueSize,
    double overheadFactor = defaultOverheadFactor,
  }) {
    // Calculate raw data size
    final dataSize = (averageKeySize + averageValueSize) * expectedEntries;

    // Add overhead for B+ tree structure
    final estimatedSize = (dataSize * overheadFactor).ceil();

    // Ensure we never return less than minimum map size
    return estimatedSize < minMapSize ? minMapSize : estimatedSize;
  }
}

/// Converts an octal string to an integer.
///
/// Throws [FormatException] if the input contains invalid octal digits.
///
/// Example:
/// `dart
/// final value = parseOctalString('644'); // Returns 420 (decimal)
/// `
int _parseOctalString(String octalStr) {
  // remove any leading zeros or '0o'
  octalStr = octalStr.replaceFirst(RegExp(r'^[0o]+'), '');

  int result = 0;
  for (int i = 0; i < octalStr.length; i++) {
    int digit = int.parse(octalStr[i]);
    if (digit >= 8) {
      throw FormatException('invalid octal number given: $digit in $octalStr');
    }
    result = result * 8 + digit;
  }
  return result;
}

/// Configuration class for LMDB initialization.
///
/// Use this class to configure database parameters during initialization.
class LMDBInitConfig {
  /// Maximum database size in bytes
  final int mapSize;

  /// Maximum number of named databases
  final int maxDbs;

  /// Maximum number of readers
  final int maxReaders;

  /// File permissions in octal format (Unix)
  final String mode;

  /// Converts the octal mode string to its integer representation.
  ///
  /// This getter automatically converts Unix-style permission strings
  /// to their decimal integer equivalent.
  ///
  /// Example:
  /// ```dart
  /// final config = LMDBInitConfig(mode: '644');
  /// print(config.modeAsInt); // Prints: 438
  /// ```
  int get modeAsInt => _parseOctalString(mode);

  /// Creates a new configuration instance.
  ///
  /// Example:
  /// ```dart
  /// final config = LMDBInitConfig(
  ///   mapSize: 1024 * 1024 * 100, // 100MB
  ///   maxDbs: 1,
  ///   mode: '644',
  /// );
  /// ```
  const LMDBInitConfig({
    required this.mapSize,
    this.maxDbs = 1,
    this.mode = "644",
    this.maxReaders = 126,
  });

  /// Creates a configuration based on expected data characteristics.
  ///
  /// This factory constructor automatically calculates the optimal
  /// map size based on your data requirements.
  ///
  /// Example:
  /// ```dart
  /// final config = LMDBInitConfig.fromEstimate(
  ///   expectedEntries: 1000000,
  ///   averageKeySize: 16,
  ///   averageValueSize: 64,
  /// );
  /// ```
  factory LMDBInitConfig.fromEstimate({
    required int expectedEntries,
    required int averageKeySize,
    required int averageValueSize,
    double overheadFactor = LMDBConfig.defaultOverheadFactor,
    int maxDbs = 1,
    int mode = 438, // 438 decimal == 644 octal
  }) {
    final mapSize = LMDBConfig.calculateMapSize(
      expectedEntries: expectedEntries,
      averageKeySize: averageKeySize,
      averageValueSize: averageValueSize,
      overheadFactor: overheadFactor,
    );

    return LMDBInitConfig(
      mapSize: mapSize,
      maxDbs: maxDbs,
      mode: mode.toRadixString(8),
    );
  }
}
