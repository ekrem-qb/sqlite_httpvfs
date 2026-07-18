import 'dart:collection';

import 'package:collection/collection.dart';

class RequestHeaders extends MapView<String, String> {
  static const _equality = MapEquality<String, String>();

  RequestHeaders(super.map);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RequestHeaders && _equality.equals(this, other);
  }

  @override
  int get hashCode => _equality.hash(this);
}

typedef SizeRequest = ({
  String url,
  RequestHeaders? headers,
});

typedef RangeRequest = ({
  String url,
  int start,
  int end,
  RequestHeaders? headers,
});
