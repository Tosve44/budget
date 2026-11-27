// Category icons: one emoji per category, the same in the web app (agreed with it; keep the two
// lists equal). A category's own `icon` wins; when it is empty the icon comes from its name.
import 'models.dart';

class CategoryIcons {
  CategoryIcons._();

  /// Used for a name that is not in [byName].
  static const fallback = '🏷️';

  /// Default icon per category name, compared without case and surrounding spaces.
  static const byName = <String, String>{
    'car': '🚗',
    'rent': '🏠',
    'groceries': '🛒',
    'food & drinks': '🍽️',
    'lunch at work': '🥪',
    'nicotine': '🚬',
    'gym & sports': '🏋️',
    'shopping': '🛍️',
    'gas': '⛽',
    'traveling': '✈️',
    'travel': '✈️',
    'saving': '🐷',
    'savings': '🐷',
    'partner balance': '🤝',
    'investing': '📈',
    'cash (atm)': '🏧',
    'barber': '💈',
    'beauty': '💅',
    'toiletries': '🧴',
    'salary': '💼',
    'other income': '💰',
    'contributions': '💶',
    'unexpected expenses': '⚠️',
  };

  /// The icons a person can pick from, in this order (same grid as the web app).
  static const choices = <String>[
    '🛒', '🍽️', '☕', '🥪', '🍕', '🍺', '🍷', '🚬', '🚗', '⛽', //
    '🚌', '🚕', '✈️', '🏨', '🏠', '💡', '💧', '📱', '🌐', '🛍️',
    '👕', '👟', '💄', '💅', '💈', '🧴', '💊', '🏥', '🏋️', '⚽',
    '🎬', '🎮', '📚', '🎁', '🐶', '👶', '🐷', '📈', '💵', '🏷️',
  ];

  /// At most this many characters, like the cloud database allows.
  static const maxLength = 16;

  static String forName(String name) => byName[name.trim().toLowerCase()] ?? fallback;

  /// The icon to show for [c].
  static String of(Category c) => c.icon.trim().isNotEmpty ? c.icon.trim() : forName(c.name);
}
