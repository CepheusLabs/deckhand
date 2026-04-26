///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:slang/generated.dart';
import 'translations.g.dart';

// Path: <root>
class TranslationsEs extends Translations with BaseTranslations<AppLocale, Translations> {
	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	TranslationsEs({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  $meta = meta ?? TranslationMetadata(
		    locale: AppLocale.es,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ),
		  super(cardinalResolver: cardinalResolver, ordinalResolver: ordinalResolver) {
		super.$meta.setFlatMapFunction($meta.getTranslation); // copy base translations to super.$meta
		$meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <es>.
	@override final TranslationMetadata<AppLocale, Translations> $meta;

	/// Access flat map
	@override dynamic operator[](String key) => $meta.getTranslation(key) ?? super.$meta.getTranslation(key);

	late final TranslationsEs _root = this; // ignore: unused_field

	@override 
	TranslationsEs $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => TranslationsEs(meta: meta ?? this.$meta);

	// Translations
	@override late final _TranslationsWelcomeEs welcome = _TranslationsWelcomeEs._(_root);
	@override late final _TranslationsPickPrinterEs pick_printer = _TranslationsPickPrinterEs._(_root);
	@override late final _TranslationsConnectEs connect = _TranslationsConnectEs._(_root);
	@override late final _TranslationsVerifyEs verify = _TranslationsVerifyEs._(_root);
	@override late final _TranslationsCommonEs common = _TranslationsCommonEs._(_root);
}

// Path: welcome
class _TranslationsWelcomeEs extends TranslationsWelcomeEn {
	_TranslationsWelcomeEs._(TranslationsEs root) : this._root = root, super.internal(root);

	final TranslationsEs _root; // ignore: unused_field

	// Translations
	@override String get title => 'Bienvenido a Deckhand';
	@override String get action_start => 'Empezar';
	@override String get action_settings => 'Configuración';
	@override late final _TranslationsWelcomeCardSafetyEs card_safety = _TranslationsWelcomeCardSafetyEs._(_root);
}

// Path: pick_printer
class _TranslationsPickPrinterEs extends TranslationsPickPrinterEn {
	_TranslationsPickPrinterEs._(TranslationsEs root) : this._root = root, super.internal(root);

	final TranslationsEs _root; // ignore: unused_field

	// Translations
	@override String get action_continue => 'Continuar';
	@override String get action_back => 'Atrás';
}

// Path: connect
class _TranslationsConnectEs extends TranslationsConnectEn {
	_TranslationsConnectEs._(TranslationsEs root) : this._root = root, super.internal(root);

	final TranslationsEs _root; // ignore: unused_field

	// Translations
	@override String get action_connect => 'Conectar';
	@override String get action_connecting => 'Conectando…';
	@override String get action_rescan => 'Volver a escanear';
}

// Path: verify
class _TranslationsVerifyEs extends TranslationsVerifyEn {
	_TranslationsVerifyEs._(TranslationsEs root) : this._root = root, super.internal(root);

	final TranslationsEs _root; // ignore: unused_field

	// Translations
	@override String get action_continue => 'Se ve bien, continuar';
}

// Path: common
class _TranslationsCommonEs extends TranslationsCommonEn {
	_TranslationsCommonEs._(TranslationsEs root) : this._root = root, super.internal(root);

	final TranslationsEs _root; // ignore: unused_field

	// Translations
	@override String get action_continue => 'Continuar';
	@override String get action_back => 'Atrás';
}

// Path: welcome.card_safety
class _TranslationsWelcomeCardSafetyEs extends TranslationsWelcomeCardSafetyEn {
	_TranslationsWelcomeCardSafetyEs._(TranslationsEs root) : this._root = root, super.internal(root);

	final TranslationsEs _root; // ignore: unused_field

	// Translations
	@override String get title => 'Seguridad';
}

/// The flat map containing all translations for locale <es>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on TranslationsEs {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'welcome.title' => 'Bienvenido a Deckhand',
			'welcome.action_start' => 'Empezar',
			'welcome.action_settings' => 'Configuración',
			'welcome.card_safety.title' => 'Seguridad',
			'pick_printer.action_continue' => 'Continuar',
			'pick_printer.action_back' => 'Atrás',
			'connect.action_connect' => 'Conectar',
			'connect.action_connecting' => 'Conectando…',
			'connect.action_rescan' => 'Volver a escanear',
			'verify.action_continue' => 'Se ve bien, continuar',
			'common.action_continue' => 'Continuar',
			'common.action_back' => 'Atrás',
			_ => null,
		};
	}
}
