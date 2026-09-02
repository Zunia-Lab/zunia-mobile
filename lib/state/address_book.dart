/// Saved recipients. Addresses are public data, so plain SharedPreferences is
/// the right store.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class AddressBookEntry {
  const AddressBookEntry({
    required this.label,
    required this.address,
    this.chainId,
  });

  factory AddressBookEntry.fromJson(Map<String, dynamic> json) =>
      AddressBookEntry(
        label: json['label'] as String,
        address: json['address'] as String,
        chainId: json['chainId'] as String?,
      );

  final String label;
  final String address;
  final String? chainId;

  Map<String, dynamic> toJson() => {
        'label': label,
        'address': address,
        if (chainId != null) 'chainId': chainId,
      };
}

const _kAddressBook = 'zunia.addressBook';

class AddressBookController extends StateNotifier<List<AddressBookEntry>> {
  AddressBookController() : super(const []) {
    _restore();
  }

  Future<void> _restore() async {
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(_kAddressBook);
    if (raw == null) return;
    state = (jsonDecode(raw) as List<dynamic>)
        .map((e) => AddressBookEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _persist(List<AddressBookEntry> rows) async {
    state = rows;
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _kAddressBook,
      jsonEncode(rows.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> save(AddressBookEntry entry) => _persist([
        ...state.where((e) => e.address != entry.address),
        entry,
      ]);

  Future<void> remove(String address) =>
      _persist(state.where((e) => e.address != address).toList());
}

final addressBookProvider =
    StateNotifierProvider<AddressBookController, List<AddressBookEntry>>(
  (ref) => AddressBookController(),
);
