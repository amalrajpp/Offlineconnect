/// 4 Gender Categories
const List<String> genderOptions = [
  'Male',
  'Female',
  'Other',
  'Prefer Not To Say',
];

/// 28 States of India
const List<String> nativityOptions = [
  'Andhra Pradesh',
  'Arunachal Pradesh',
  'Assam',
  'Bihar',
  'Chhattisgarh',
  'Goa',
  'Gujarat',
  'Haryana',
  'Himachal Pradesh',
  'Jharkhand',
  'Karnataka',
  'Kerala',
  'Madhya Pradesh',
  'Maharashtra',
  'Manipur',
  'Meghalaya',
  'Mizoram',
  'Nagaland',
  'Odisha',
  'Punjab',
  'Rajasthan',
  'Sikkim',
  'Tamil Nadu',
  'Telangana',
  'Tripura',
  'Uttar Pradesh',
  'Uttarakhand',
  'West Bengal',
];

/// Helper to get gender name safely
String getGenderName(int gender) {
  if (gender < 0 || gender >= genderOptions.length) return 'Unknown';
  return genderOptions[gender];
}

/// Helper to get nativity name safely
String getNativityName(int nativity) {
  if (nativity < 0 || nativity >= nativityOptions.length) return 'Unknown';
  return nativityOptions[nativity];
}
