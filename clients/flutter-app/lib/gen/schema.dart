// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'package:colyseus/colyseus.dart';

final class MoveInput extends SchemaRef {
  MoveInput(super.handle);

  double get moveX => view['moveX'];
  double get moveY => view['moveY'];
}

final class Player extends SchemaRef {
  Player(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  double get vx => view['vx'];
  double get vy => view['vy'];
  double get hue => view['hue'];
}

final class MoveState extends SchemaRef {
  MoveState(super.handle);

  MapSchema<Player> get players => mapOf('players', Player.new);
}

final class Bot extends SchemaRef {
  Bot(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  double get vx => view['vx'];
  double get vy => view['vy'];
  String get kind => view.getString('kind') ?? '';
  double get minX => view['minX'];
  double get maxX => view['maxX'];
  double get baseY => view['baseY'];
  double get phaseMs => view['phaseMs'];
  double get speed => view['speed'];
  double get lastTeleport => view['lastTeleport'];
}

final class BotsState extends SchemaRef {
  BotsState(super.handle);

  MapSchema<Player> get players => mapOf('players', Player.new);
  MapSchema<Bot> get bots => mapOf('bots', Bot.new);
}

final class BumpPlayer extends SchemaRef {
  BumpPlayer(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  double get vx => view['vx'];
  double get vy => view['vy'];
  double get hue => view['hue'];
  double get bumpTicks => view['bumpTicks'];
  double get bumps => view['bumps'];
}

final class BumpState extends SchemaRef {
  BumpState(super.handle);

  MapSchema<BumpPlayer> get players => mapOf('players', BumpPlayer.new);
  MapSchema<Bot> get bots => mapOf('bots', Bot.new);
}

final class GoalPlayer extends SchemaRef {
  GoalPlayer(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  double get vx => view['vx'];
  double get vy => view['vy'];
  double get hue => view['hue'];
  double get score => view['score'];
  double get scoreTicks => view['scoreTicks'];
}

final class GoalState extends SchemaRef {
  GoalState(super.handle);

  MapSchema<GoalPlayer> get players => mapOf('players', GoalPlayer.new);
  double get denyRate => view['denyRate'];
}

final class Puck extends SchemaRef {
  Puck(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  double get vx => view['vx'];
  double get vy => view['vy'];
}

final class HockeyState extends SchemaRef {
  HockeyState(super.handle);

  MapSchema<Player> get players => mapOf('players', Player.new);
  Puck? get puck => refOf('puck', Puck.new);
  bool get botEnabled => view.getBool('botEnabled');
}

final class RangeInput extends SchemaRef {
  RangeInput(super.handle);

  double get moveX => view['moveX'];
  double get moveY => view['moveY'];
  double get aimX => view['aimX'];
  double get aimY => view['aimY'];
  bool get fire => view.getBool('fire');
  bool get spread => view.getBool('spread');
}

final class RangePlayer extends SchemaRef {
  RangePlayer(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  double get vx => view['vx'];
  double get vy => view['vy'];
  double get hue => view['hue'];
  double get shots => view['shots'];
  double get hits => view['hits'];
}

final class RangeState extends SchemaRef {
  RangeState(super.handle);

  MapSchema<RangePlayer> get players => mapOf('players', RangePlayer.new);
  MapSchema<Bot> get bots => mapOf('bots', Bot.new);
  bool get lagComp => view.getBool('lagComp');
  double get salt => view['salt'];
}

final class Projectile extends SchemaRef {
  Projectile(super.handle);

  double get x => view['x'];
  double get y => view['y'];
  double get vx => view['vx'];
  double get vy => view['vy'];
  String get owner => view.getString('owner') ?? '';
  double get bornMs => view['bornMs'];
}

final class ProjectileState extends SchemaRef {
  ProjectileState(super.handle);

  MapSchema<Player> get players => mapOf('players', Player.new);
  MapSchema<Projectile> get projectiles => mapOf('projectiles', Projectile.new);
}
