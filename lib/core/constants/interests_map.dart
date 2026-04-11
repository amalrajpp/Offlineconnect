/// 6 Main Categories (Fields) for Byte 26
const List<String> mainFields = [
  'Tech / Dev',     // 0
  'Music / Audio',  // 1
  'Pop Culture',    // 2
  'Gaming',         // 3
  'Just Chilling',  // 4
  'Nativity / State', // 5
];

/// Subfields mapping. Each index corresponds to the mainFields index.
/// Has up to 16 strings per category.
const Map<int, List<String>> subfieldsMap = {
  0: ['Web Dev', 'AI / ML', 'Mobile / App', 'Hardware / IoT', 'Cybersec', 'Data / Analytics', 'Crypto', 'Game Dev', 'Open Source', 'UI/UX', 'Cloud / DevOps', 'Robotics', 'SysAdmin', 'Startup / Build', 'Tech News', 'Other Tech'],
  1: ['Hip-Hop / Rap', 'EDM / Rave', 'Indie / Alt', 'K-Pop', 'Rock / Punk', 'Metal / Core', 'R&B / Soul', 'Jazz / Blues', 'Produce / Make', 'Classical', 'Country', 'DJing', 'Lo-Fi / Study', 'Pop / Top 40', 'Live Shows', 'Other Music'],
  2: ['Movies / Film', 'TV Shows / Binge', 'YouTube / Web', 'Podcasts', 'Memes / Lore', 'Celebrity Tea', 'Reality TV', 'Comics / Marvel', 'Sci-Fi / Fantasy', 'Board Games', 'True Crime', 'Standup Comedy', 'Streaming / Twitch', 'K-Dramas', 'Musical Theater', 'Other Pop Cult'],
  3: ['FPS / Valo', 'MOBAs / LoL', 'Cozy / Stardew', 'Fighting / FGC', 'MMOs / WoW', 'Gacha / Genshin', 'Tabletop / D&D', 'Retro / Arcade', 'Console / PS', 'PC Master Race', 'VR / AR', 'Speedrunning', 'Indie Games', 'Rhythm Games', 'Mobile / Casual', 'Other Gaming'],
  4: ['Rotting in bed', 'Scrolling', 'People Watching', 'Window Shopping', 'Napping', 'Daydreaming', 'Listening to Music', 'Staring at Wall', 'Procrastinating', 'Vibing', 'Deep Talks', 'Silent Co-exist', 'Sunbathing', 'Overthinking', 'Waiting for text', 'Just Existing'],
  5: ['Maharashtra', 'Karnataka', 'Tamil Nadu', 'Delhi / NCR', 'Gujarat', 'Kerala', 'UP / Bihar', 'West Bengal', 'Punjab / Haryana', 'Rajasthan', 'AP / Telangana', 'MP / CG', 'Odisha / JH', 'North East', 'Goa', 'Other'],
};

/// Helper to get subfield name safely
String getSubfieldName(int fieldId, int subfieldId) {
  if (subfieldId < 0 || subfieldId >= 16) return 'Unknown';
  final list = subfieldsMap[fieldId];
  if (list == null || subfieldId >= list.length) {
    return 'Other';
  }
  return list[subfieldId];
}

/// Helper to get field name safely
String getFieldName(int fieldId) {
  if (fieldId < 0 || fieldId >= mainFields.length) return 'Other';
  return mainFields[fieldId];
}
