class AppAssets {
  /// Defines the total number of processed avatar images placed in `assets/avatars/`.
  /// The avatars are sequentially named `avatar_0.jpg` through `avatar_59.jpg`.
  static const int maxAvatars = 60;

  /// Helper to get the correct avatar path safely
  static String getAvatarPath(int avatarId) {
    // If the avatarId somehow exceeds bounds, default to 0
    if (avatarId < 0 || avatarId >= maxAvatars) {
      return 'assets/avatars/avatar_0.jpg';
    }
    return 'assets/avatars/avatar_$avatarId.jpg';
  }
}
