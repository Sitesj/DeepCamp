/*
 * Deer Camp core logic — pure functions shared by the app (browser) and the
 * automated tests (Node). No DOM, no network, no storage in this file.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.DeerCore = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var APP_VERSION = '1.1.0';
  var EXPORT_SCHEMA = 'deer-camp-hunt-export';
  var EXPORT_SCHEMA_VERSION = 2; // 2: per-type counts (buck/doe/fawn/unknown) in each sighting

  // ---------------------------------------------------------------- Compass
  var DIRECTIONS = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
    'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
  var DIRECTION_NAMES = {
    N: 'North', NNE: 'North-northeast', NE: 'Northeast', ENE: 'East-northeast',
    E: 'East', ESE: 'East-southeast', SE: 'Southeast', SSE: 'South-southeast',
    S: 'South', SSW: 'South-southwest', SW: 'Southwest', WSW: 'West-southwest',
    W: 'West', WNW: 'West-northwest', NW: 'Northwest', NNW: 'North-northwest'
  };

  function bearingFor(direction) {
    var i = DIRECTIONS.indexOf(direction);
    if (i < 0) return null;
    return i * 22.5;
  }

  function directionFor(bearing) {
    if (typeof bearing !== 'number' || !isFinite(bearing)) return null;
    var b = ((bearing % 360) + 360) % 360;
    return DIRECTIONS[Math.round(b / 22.5) % 16];
  }

  function isDirection(d) { return DIRECTIONS.indexOf(d) >= 0; }

  // --------------------------------------------------------------- Distance
  var YARD_METERS = 0.9144;
  var DISTANCE_RANGES = [
    { key: '0-25', label: '0–25 yards', min: 0, max: 25 },
    { key: '25-50', label: '25–50 yards', min: 25, max: 50 },
    { key: '50-75', label: '50–75 yards', min: 50, max: 75 },
    { key: '75-100', label: '75–100 yards', min: 75, max: 100 },
    { key: '100-200', label: '100–200 yards', min: 100, max: 200 }
  ];

  function distanceRange(key) {
    for (var i = 0; i < DISTANCE_RANGES.length; i++) {
      if (DISTANCE_RANGES[i].key === key) return DISTANCE_RANGES[i];
    }
    return null;
  }

  function midpointYards(key) {
    var r = distanceRange(key);
    return r ? (r.min + r.max) / 2 : null;
  }

  // ---------------------------------------------------------------- Geodesy
  var EARTH_RADIUS_M = 6371008.8; // mean Earth radius
  function toRad(d) { return d * Math.PI / 180; }
  function toDeg(r) { return r * 180 / Math.PI; }

  /** Great-circle destination point from a start point, bearing and distance. */
  function destinationPoint(lat, lng, bearingDeg, distanceM) {
    var d = distanceM / EARTH_RADIUS_M;
    var th = toRad(bearingDeg);
    var p1 = toRad(lat), l1 = toRad(lng);
    var sinP2 = Math.sin(p1) * Math.cos(d) + Math.cos(p1) * Math.sin(d) * Math.cos(th);
    var p2 = Math.asin(Math.max(-1, Math.min(1, sinP2)));
    var y = Math.sin(th) * Math.sin(d) * Math.cos(p1);
    var x = Math.cos(d) - Math.sin(p1) * sinP2;
    var l2 = l1 + Math.atan2(y, x);
    var lngOut = ((toDeg(l2) + 540) % 360) - 180;
    return { lat: toDeg(p2), lng: lngOut };
  }

  /** Haversine distance in meters. */
  function distanceMeters(lat1, lng1, lat2, lng2) {
    var p1 = toRad(lat1), p2 = toRad(lat2);
    var dp = toRad(lat2 - lat1), dl = toRad(lng2 - lng1);
    var a = Math.sin(dp / 2) * Math.sin(dp / 2) +
      Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2);
    return 2 * EARTH_RADIUS_M * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }

  /** Initial bearing (degrees) from point 1 to point 2. */
  function initialBearing(lat1, lng1, lat2, lng2) {
    var p1 = toRad(lat1), p2 = toRad(lat2), dl = toRad(lng2 - lng1);
    var y = Math.sin(dl) * Math.cos(p2);
    var x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
    return (toDeg(Math.atan2(y, x)) + 360) % 360;
  }

  /**
   * Estimated first-seen deer location: stand position moved along the
   * first-seen bearing by the midpoint of the reported distance range.
   * This is an approximate, derived value.
   */
  function estimateSightingLocation(standLat, standLng, firstSeenBearing, distanceKey) {
    var yards = midpointYards(distanceKey);
    if (yards === null || typeof firstSeenBearing !== 'number' ||
      typeof standLat !== 'number' || typeof standLng !== 'number') return null;
    return destinationPoint(standLat, standLng, firstSeenBearing, yards * YARD_METERS);
  }

  /** Polygon (array of [lat,lng]) covering bearing ±halfWidth and the distance range. */
  function uncertaintySector(standLat, standLng, bearing, distanceKey, halfWidth, steps) {
    var r = distanceRange(distanceKey);
    if (!r) return [];
    halfWidth = halfWidth == null ? 11.25 : halfWidth;
    steps = steps || 8;
    var minM = r.min * YARD_METERS, maxM = r.max * YARD_METERS;
    var pts = [], i, b, p;
    for (i = 0; i <= steps; i++) {
      b = bearing - halfWidth + (2 * halfWidth * i / steps);
      p = destinationPoint(standLat, standLng, b, maxM);
      pts.push([p.lat, p.lng]);
    }
    if (minM <= 0.5) {
      pts.push([standLat, standLng]);
    } else {
      for (i = steps; i >= 0; i--) {
        b = bearing - halfWidth + (2 * halfWidth * i / steps);
        p = destinationPoint(standLat, standLng, b, minM);
        pts.push([p.lat, p.lng]);
      }
    }
    return pts;
  }

  /**
   * A ray from (x,y) inside a w×h rectangle, heading along a compass bearing
   * (screen up = north), ends where it meets the rectangle inset by margin.
   * Returns null if the start point is outside the inset rectangle.
   */
  function rayToRectEdge(x, y, bearing, w, h, margin) {
    margin = margin || 0;
    var minX = margin, minY = margin, maxX = w - margin, maxY = h - margin;
    if (x < minX || x > maxX || y < minY || y > maxY) return null;
    var dx = Math.sin(toRad(bearing));
    var dy = -Math.cos(toRad(bearing));
    var t = Infinity;
    if (dx > 1e-9) t = Math.min(t, (maxX - x) / dx);
    if (dx < -1e-9) t = Math.min(t, (minX - x) / dx);
    if (dy > 1e-9) t = Math.min(t, (maxY - y) / dy);
    if (dy < -1e-9) t = Math.min(t, (minY - y) / dy);
    if (!isFinite(t)) return { x: x, y: y, length: 0 };
    return { x: x + dx * t, y: y + dy * t, length: t };
  }

  // ------------------------------------------------------------------ Misc
  function uuid() {
    var c = (typeof crypto !== 'undefined') ? crypto : null;
    if (c && typeof c.randomUUID === 'function') return c.randomUUID();
    var b = new Uint8Array(16);
    if (c && c.getRandomValues) c.getRandomValues(b);
    else for (var i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var h = [];
    for (var j = 0; j < 16; j++) h.push((b[j] + 0x100).toString(16).slice(1));
    return h.slice(0, 4).join('') + '-' + h.slice(4, 6).join('') + '-' + h.slice(6, 8).join('') +
      '-' + h.slice(8, 10).join('') + '-' + h.slice(10, 16).join('');
  }

  var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  function isUuid(s) { return typeof s === 'string' && UUID_RE.test(s); }

  function isIsoTimestamp(s) {
    return typeof s === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(s) && !isNaN(Date.parse(s));
  }

  function nowIso() { return new Date().toISOString(); }

  /** Local calendar date YYYY-MM-DD for a timestamp (device time zone). */
  function localDateKey(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return null;
    var m = d.getMonth() + 1, day = d.getDate();
    return d.getFullYear() + '-' + (m < 10 ? '0' : '') + m + '-' + (day < 10 ? '0' : '') + day;
  }

  /** Start (inclusive) and end (exclusive) epoch ms of a local YYYY-MM-DD date. */
  function localDayBounds(dateKey) {
    var p = String(dateKey).split('-').map(Number);
    var start = new Date(p[0], p[1] - 1, p[2], 0, 0, 0, 0).getTime();
    var end = new Date(p[0], p[1] - 1, p[2] + 1, 0, 0, 0, 0).getTime();
    return { start: start, end: end };
  }

  // One sighting can be a mixed group: a count is kept for each type.
  var DEER_TYPES = ['buck', 'doe', 'fawn', 'unknown'];
  var COUNT_FIELDS = { buck: 'buck_count', doe: 'doe_count', fawn: 'fawn_count', unknown: 'unknown_count' };
  var TYPE_NAMES = { buck: ['Buck', 'Bucks'], doe: ['Doe', 'Does'], fawn: ['Fawn', 'Fawns'], unknown: ['Unknown', 'Unknown'] };

  /** Counts per type. Older records (one type + quantity) are read the same way. */
  function deerCounts(rec) {
    var c = { buck: 0, doe: 0, fawn: 0, unknown: 0 }, any = false;
    DEER_TYPES.forEach(function (t) {
      var v = rec && rec[COUNT_FIELDS[t]];
      if (typeof v === 'number' && v > 0) { c[t] = v; any = true; }
    });
    if (!any && rec && rec.quantity > 0 && DEER_TYPES.indexOf(rec.deer_type) >= 0) c[rec.deer_type] = rec.quantity;
    return c;
  }

  /** 'buck' | 'doe' | 'fawn' | 'unknown' when only one type was seen, 'mixed' otherwise. */
  function groupType(counts) {
    var nz = DEER_TYPES.filter(function (t) { return counts[t] > 0; });
    return nz.length === 1 ? nz[0] : (nz.length ? 'mixed' : null);
  }

  function totalOf(counts, types) {
    return (types || DEER_TYPES).reduce(function (n, t) { return n + (counts[t] || 0); }, 0);
  }

  /** "3 Does, 1 Buck, 2 Fawns". Accepts a sighting record, or (quantity, type). */
  function deerLabel(recOrQty, type) {
    var c;
    if (recOrQty && typeof recOrQty === 'object') c = deerCounts(recOrQty);
    else { c = { buck: 0, doe: 0, fawn: 0, unknown: 0 }; c[DEER_TYPES.indexOf(type) >= 0 ? type : 'unknown'] = recOrQty || 1; }
    var parts = DEER_TYPES.filter(function (t) { return c[t] > 0; }).map(function (t) {
      return c[t] + ' ' + (t === 'unknown' ? 'Unknown' : TYPE_NAMES[t][c[t] === 1 ? 0 : 1]);
    });
    return parts.length ? parts.join(', ') : '0 Deer';
  }

  /** Fill in per-type counts for records made before mixed groups existed. */
  function normalizeSighting(o) {
    if (!o || typeof o !== 'object') return o;
    var has = DEER_TYPES.some(function (t) { return typeof o[COUNT_FIELDS[t]] === 'number'; });
    if (has) return o;
    var c = deerCounts(o), out = Object.assign({}, o);
    DEER_TYPES.forEach(function (t) { out[COUNT_FIELDS[t]] = c[t]; });
    return out;
  }

  var WEATHER_CODES = {
    0: 'Clear', 1: 'Mostly clear', 2: 'Partly cloudy', 3: 'Overcast',
    45: 'Fog', 48: 'Freezing fog', 51: 'Light drizzle', 53: 'Drizzle', 55: 'Heavy drizzle',
    56: 'Freezing drizzle', 57: 'Freezing drizzle', 61: 'Light rain', 63: 'Rain', 65: 'Heavy rain',
    66: 'Freezing rain', 67: 'Freezing rain', 71: 'Light snow', 73: 'Snow', 75: 'Heavy snow',
    77: 'Snow grains', 80: 'Rain showers', 81: 'Rain showers', 82: 'Heavy rain showers',
    85: 'Snow showers', 86: 'Heavy snow showers', 95: 'Thunderstorm', 96: 'Thunderstorm with hail',
    99: 'Thunderstorm with hail'
  };
  function weatherCodeText(code) {
    if (code === null || code === undefined) return null;
    return WEATHER_CODES[code] || ('Code ' + code);
  }

  function numOrNull(v) { return (typeof v === 'number' && isFinite(v)) ? v : null; }

  /**
   * Choose the weather snapshot to attach to an observation from a cached
   * Open-Meteo response. Never invents values: missing ones stay null.
   * kind: 'forecast' when retrieved within the last hour (Open-Meteo values
   * are model output, not station observations); 'cached' when older.
   */
  function pickWeather(cache, observedIso, nowMs) {
    if (!cache || !cache.retrieved_at) return null;
    var obsMs = Date.parse(observedIso);
    var retrievedMs = Date.parse(cache.retrieved_at);
    if (isNaN(obsMs) || isNaN(retrievedMs)) return null;
    nowMs = nowMs || Date.now();
    var best = null, bestDiff = Infinity;
    var h = cache.hourly;
    if (h && h.time && h.time.length) {
      for (var i = 0; i < h.time.length; i++) {
        var t = Date.parse(h.time[i]);
        var diff = Math.abs(t - obsMs);
        if (diff < bestDiff) { bestDiff = diff; best = i; }
      }
    }
    var c = cache.current;
    // "Current conditions" are preferred when they are close to the observation time.
    var useCurrent = c && c.time && Math.abs(Date.parse(c.time) - obsMs) <= 45 * 60000;
    var snap;
    if (useCurrent) {
      snap = {
        weather_time: new Date(Date.parse(c.time)).toISOString(),
        temperature_f: numOrNull(c.temperature_2m),
        wind_speed_mph: numOrNull(c.wind_speed_10m),
        wind_direction_deg: numOrNull(c.wind_direction_10m),
        pressure_hpa: numOrNull(c.pressure_msl),
        precipitation_in: numOrNull(c.precipitation),
        weather_code: numOrNull(c.weather_code)
      };
    } else if (best !== null && bestDiff <= 90 * 60000) {
      snap = {
        weather_time: new Date(Date.parse(h.time[best])).toISOString(),
        temperature_f: numOrNull(h.temperature_2m && h.temperature_2m[best]),
        wind_speed_mph: numOrNull(h.wind_speed_10m && h.wind_speed_10m[best]),
        wind_direction_deg: numOrNull(h.wind_direction_10m && h.wind_direction_10m[best]),
        pressure_hpa: numOrNull(h.pressure_msl && h.pressure_msl[best]),
        precipitation_in: numOrNull(h.precipitation && h.precipitation[best]),
        weather_code: numOrNull(h.weather_code && h.weather_code[best])
      };
    } else {
      return null;
    }
    snap.source = 'open-meteo';
    snap.kind = (nowMs - retrievedMs) <= 60 * 60000 ? 'forecast' : 'cached';
    snap.retrieved_at = new Date(retrievedMs).toISOString();
    snap.conditions = weatherCodeText(snap.weather_code);
    return snap;
  }

  // ----------------------------------------------------------- Validation
  function err(list, msg) { list.push(msg); }

  function validateStand(s) {
    var e = [];
    if (!s || typeof s !== 'object') return ['Stand is not an object'];
    if (!isUuid(s.id)) err(e, 'Stand id must be a UUID');
    if (typeof s.name !== 'string' || !s.name.trim()) err(e, 'Stand name is required');
    if (typeof s.latitude !== 'number' || s.latitude < -90 || s.latitude > 90) err(e, 'Stand latitude invalid');
    if (typeof s.longitude !== 'number' || s.longitude < -180 || s.longitude > 180) err(e, 'Stand longitude invalid');
    return e;
  }

  function validateSession(s) {
    var e = [];
    if (!s || typeof s !== 'object') return ['Session is not an object'];
    if (!isUuid(s.id)) err(e, 'Session id must be a UUID');
    if (!isUuid(s.hunter_id)) err(e, 'Session hunter_id must be a UUID');
    if (!isUuid(s.stand_id)) err(e, 'Session stand_id must be a UUID');
    if (!isIsoTimestamp(s.started_at)) err(e, 'Session started_at must be an ISO timestamp');
    if (s.ended_at != null) {
      if (!isIsoTimestamp(s.ended_at)) err(e, 'Session ended_at must be an ISO timestamp or null');
      else if (Date.parse(s.ended_at) < Date.parse(s.started_at)) err(e, 'Session ends before it starts');
    }
    return e;
  }

  function validateCommonObservation(o, e) {
    if (!isUuid(o.id)) err(e, 'id must be a UUID');
    if (!isUuid(o.hunter_id)) err(e, 'hunter_id must be a UUID');
    if (!isUuid(o.stand_id)) err(e, 'stand_id must be a UUID');
    if (!isUuid(o.session_id)) err(e, 'session_id must be a UUID');
    if (!isIsoTimestamp(o.observed_at)) err(e, 'observed_at must be an ISO timestamp');
    if (typeof o.stand_latitude !== 'number' || o.stand_latitude < -90 || o.stand_latitude > 90) err(e, 'stand_latitude invalid');
    if (typeof o.stand_longitude !== 'number' || o.stand_longitude < -180 || o.stand_longitude > 180) err(e, 'stand_longitude invalid');
    if (o.status != null && o.status !== 'active' && o.status !== 'voided') err(e, 'status must be active or voided');
  }

  function validateSighting(o) {
    var e = [];
    if (!o || typeof o !== 'object') return ['Sighting is not an object'];
    validateCommonObservation(o, e);
    if (!isDirection(o.first_seen_direction)) err(e, 'first_seen_direction invalid');
    else if (o.first_seen_bearing !== bearingFor(o.first_seen_direction)) err(e, 'first_seen_bearing does not match direction');
    var r = distanceRange(o.distance_range);
    if (!r) err(e, 'distance_range invalid');
    if (o.heading_direction == null) {
      if (o.heading_bearing != null) err(e, 'heading_bearing must be null when heading unknown');
    } else if (!isDirection(o.heading_direction)) err(e, 'heading_direction invalid');
    else if (o.heading_bearing !== bearingFor(o.heading_direction)) err(e, 'heading_bearing does not match direction');
    if (typeof o.quantity !== 'number' || o.quantity % 1 !== 0 || o.quantity < 1 || o.quantity > 500) err(e, 'quantity must be a whole number 1–500');
    var badCount = DEER_TYPES.some(function (t) {
      var v = o[COUNT_FIELDS[t]];
      return typeof v !== 'number' || v % 1 !== 0 || v < 0 || v > 500;
    });
    if (badCount) err(e, 'buck/doe/fawn/unknown counts must be whole numbers 0–500');
    else {
      var c = deerCounts(o);
      if (totalOf(c) !== o.quantity) err(e, 'counts do not add up to quantity');
      if (o.deer_type !== groupType(c)) err(e, 'deer_type does not match counts');
    }
    return e;
  }

  function validateGunshot(o) {
    var e = [];
    if (!o || typeof o !== 'object') return ['Gunshot report is not an object'];
    validateCommonObservation(o, e);
    if (!isDirection(o.direction)) err(e, 'direction invalid');
    else if (o.bearing !== bearingFor(o.direction)) err(e, 'bearing does not match direction');
    return e;
  }

  // ------------------------------------------------------ Record builders
  function buildSession(opts) {
    return {
      id: opts.id || uuid(),
      hunter_id: opts.hunter_id,
      stand_id: opts.stand.id,
      started_at: opts.started_at || nowIso(),
      ended_at: null,
      stand_latitude: opts.stand.latitude,
      stand_longitude: opts.stand.longitude
    };
  }

  function buildSighting(opts) {
    var stand = opts.stand;
    var fsb = bearingFor(opts.first_seen_direction);
    var hb = opts.heading_direction ? bearingFor(opts.heading_direction) : null;
    var r = distanceRange(opts.distance_range);
    // counts: {buck, doe, fawn, unknown}; (quantity, deer_type) still accepted for a single type
    var counts = { buck: 0, doe: 0, fawn: 0, unknown: 0 };
    if (opts.counts) DEER_TYPES.forEach(function (t) { counts[t] = Math.max(0, Math.floor(opts.counts[t] || 0)); });
    else counts[DEER_TYPES.indexOf(opts.deer_type) >= 0 ? opts.deer_type : 'unknown'] = opts.quantity || 1;
    var est = estimateSightingLocation(stand.latitude, stand.longitude, fsb, opts.distance_range);
    return {
      id: opts.id || uuid(),
      hunter_id: opts.hunter_id,
      stand_id: stand.id,
      session_id: opts.session_id,
      observed_at: opts.observed_at,
      first_seen_direction: opts.first_seen_direction,
      first_seen_bearing: fsb,
      distance_range: opts.distance_range,
      distance_min_yards: r ? r.min : null,
      distance_max_yards: r ? r.max : null,
      heading_direction: opts.heading_direction || null,
      heading_bearing: hb,
      quantity: totalOf(counts),
      deer_type: groupType(counts),
      buck_count: counts.buck,
      doe_count: counts.doe,
      fawn_count: counts.fawn,
      unknown_count: counts.unknown,
      stand_latitude: stand.latitude,
      stand_longitude: stand.longitude,
      est_latitude: est ? est.lat : null,
      est_longitude: est ? est.lng : null,
      weather: opts.weather || null,
      status: 'active',
      voided_at: null,
      void_reason: null,
      corrects_id: opts.corrects_id || null,
      recorded_at: opts.recorded_at || nowIso()
    };
  }

  function buildGunshot(opts) {
    var stand = opts.stand;
    return {
      id: opts.id || uuid(),
      hunter_id: opts.hunter_id,
      stand_id: stand.id,
      session_id: opts.session_id,
      observed_at: opts.observed_at,
      direction: opts.direction,
      bearing: bearingFor(opts.direction),
      stand_latitude: stand.latitude,
      stand_longitude: stand.longitude,
      weather: opts.weather || null,
      status: 'active',
      voided_at: null,
      void_reason: null,
      corrects_id: opts.corrects_id || null,
      recorded_at: opts.recorded_at || nowIso()
    };
  }

  // Fields that are sent to / received from the server (no local "_" fields).
  var SERVER_FIELDS = {
    hunting_sessions: ['id', 'hunter_id', 'stand_id', 'started_at', 'ended_at', 'stand_latitude', 'stand_longitude'],
    deer_sightings: ['id', 'hunter_id', 'stand_id', 'session_id', 'observed_at', 'first_seen_direction',
      'first_seen_bearing', 'distance_range', 'distance_min_yards', 'distance_max_yards', 'heading_direction',
      'heading_bearing', 'quantity', 'deer_type', 'buck_count', 'doe_count', 'fawn_count', 'unknown_count', 'stand_latitude', 'stand_longitude', 'est_latitude',
      'est_longitude', 'weather', 'status', 'voided_at', 'void_reason', 'corrects_id', 'recorded_at'],
    gunshot_reports: ['id', 'hunter_id', 'stand_id', 'session_id', 'observed_at', 'direction', 'bearing',
      'stand_latitude', 'stand_longitude', 'weather', 'status', 'voided_at', 'void_reason', 'corrects_id',
      'recorded_at']
  };

  function pick(rec, fields) {
    var out = {};
    for (var i = 0; i < fields.length; i++) {
      var f = fields[i];
      out[f] = rec[f] === undefined ? null : rec[f];
    }
    return out;
  }

  function toServer(table, rec) { return pick(rec, SERVER_FIELDS[table]); }

  // -------------------------------------------------------- Export/Import
  /**
   * Build an export object. `filter` is one of:
   *   {type:'all'} | {type:'session', session_id} | {type:'date', date:'YYYY-MM-DD'}
   *   | {type:'range', from:'YYYY-MM-DD', to:'YYYY-MM-DD'}
   */
  function buildExport(data, filter, exportedAt) {
    filter = filter || { type: 'all' };
    var inRange;
    if (filter.type === 'date') {
      var b = localDayBounds(filter.date);
      inRange = function (iso) { var t = Date.parse(iso); return t >= b.start && t < b.end; };
    } else if (filter.type === 'range') {
      var s = localDayBounds(filter.from).start, en = localDayBounds(filter.to).end;
      inRange = function (iso) { var t = Date.parse(iso); return t >= s && t < en; };
    } else {
      inRange = function () { return true; };
    }
    var sessions, sightings, gunshots;
    if (filter.type === 'session') {
      sessions = (data.sessions || []).filter(function (x) { return x.id === filter.session_id; });
      sightings = (data.sightings || []).filter(function (x) { return x.session_id === filter.session_id; });
      gunshots = (data.gunshots || []).filter(function (x) { return x.session_id === filter.session_id; });
    } else {
      sightings = (data.sightings || []).filter(function (x) { return inRange(x.observed_at); });
      gunshots = (data.gunshots || []).filter(function (x) { return inRange(x.observed_at); });
      var used = {};
      sightings.concat(gunshots).forEach(function (x) { used[x.session_id] = true; });
      sessions = (data.sessions || []).filter(function (x) {
        return used[x.id] || inRange(x.started_at) || (x.ended_at && inRange(x.ended_at));
      });
    }
    var standIds = {}, hunterIds = {};
    sessions.concat(sightings, gunshots).forEach(function (x) { standIds[x.stand_id] = true; hunterIds[x.hunter_id] = true; });
    var stands = (data.stands || []).filter(function (s) { return filter.type === 'all' || standIds[s.id]; })
      .map(function (s) {
        return { id: s.id, name: s.name, latitude: s.latitude, longitude: s.longitude,
          description: s.description || null, is_active: s.is_active !== false };
      });
    var hunters = (data.hunters || []).filter(function (h) { return hunterIds[h.id]; })
      .map(function (h) { return { id: h.id, display_name: h.display_name }; });
    var byTime = function (k) { return function (a, b) { return Date.parse(a[k]) - Date.parse(b[k]); }; };
    return {
      schema: EXPORT_SCHEMA,
      schema_version: EXPORT_SCHEMA_VERSION,
      app_version: APP_VERSION,
      exported_at: exportedAt || nowIso(),
      scope: filter,
      hunters: hunters,
      stands: stands,
      sessions: sessions.map(function (x) { return toServer('hunting_sessions', x); }).sort(byTime('started_at')),
      deer_sightings: sightings.map(function (x) { return toServer('deer_sightings', x); }).sort(byTime('observed_at')),
      gunshot_reports: gunshots.map(function (x) { return toServer('gunshot_reports', x); }).sort(byTime('observed_at'))
    };
  }

  /**
   * Validate a parsed export object. Returns
   *   {ok, errors[], skipped[], data:{hunters,stands,sessions,sightings,gunshots}}
   * Structural problems make ok=false. Individually invalid records are
   * skipped and reported.
   */
  function validateImport(obj) {
    var errors = [], skipped = [];
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return { ok: false, errors: ['File is not a Deer Camp JSON object'], skipped: [] };
    if (obj.schema !== EXPORT_SCHEMA) errors.push('Not a Deer Camp hunt export (schema missing or wrong)');
    if (typeof obj.schema_version !== 'number') errors.push('schema_version missing');
    else if (obj.schema_version > EXPORT_SCHEMA_VERSION) errors.push('File was made by a newer version of Deer Camp (schema ' + obj.schema_version + ')');
    ['stands', 'sessions', 'deer_sightings', 'gunshot_reports'].forEach(function (k) {
      if (!Array.isArray(obj[k])) errors.push('"' + k + '" list is missing');
    });
    if (obj.hunters != null && !Array.isArray(obj.hunters)) errors.push('"hunters" must be a list');
    if (errors.length) return { ok: false, errors: errors, skipped: [] };

    function collect(list, validator, label) {
      var out = [], seen = {};
      list.forEach(function (r, i) {
        var e = validator(r);
        if (e.length) { skipped.push(label + ' #' + (i + 1) + ': ' + e[0]); return; }
        if (seen[r.id]) return; // duplicate inside the file
        seen[r.id] = true;
        out.push(r);
      });
      return out;
    }
    var stands = collect(obj.stands, validateStand, 'Stand');
    var sessions = collect(obj.sessions, validateSession, 'Session');
    var sightings = collect(obj.deer_sightings.map(normalizeSighting), validateSighting, 'Deer sighting');
    var gunshots = collect(obj.gunshot_reports, validateGunshot, 'Gunshot report');
    var hunters = (obj.hunters || []).filter(function (h) {
      return h && isUuid(h.id) && typeof h.display_name === 'string';
    });
    return {
      ok: true, errors: [], skipped: skipped,
      data: { hunters: hunters, stands: stands, sessions: sessions, sightings: sightings, gunshots: gunshots }
    };
  }

  // ---------------------------------------------------------------- Events
  /** Merge sightings and gunshots into one list sorted by original observation time. */
  function timeline(sightings, gunshots) {
    var ev = [];
    (sightings || []).forEach(function (s) { ev.push({ kind: 'deer', t: Date.parse(s.observed_at), rec: s }); });
    (gunshots || []).forEach(function (g) { ev.push({ kind: 'gunshot', t: Date.parse(g.observed_at), rec: g }); });
    ev.sort(function (a, b) { return a.t - b.t || (a.rec.id < b.rec.id ? -1 : 1); });
    return ev;
  }

  return {
    APP_VERSION: APP_VERSION,
    EXPORT_SCHEMA: EXPORT_SCHEMA,
    EXPORT_SCHEMA_VERSION: EXPORT_SCHEMA_VERSION,
    DIRECTIONS: DIRECTIONS,
    DIRECTION_NAMES: DIRECTION_NAMES,
    DISTANCE_RANGES: DISTANCE_RANGES,
    DEER_TYPES: DEER_TYPES,
    YARD_METERS: YARD_METERS,
    SERVER_FIELDS: SERVER_FIELDS,
    bearingFor: bearingFor,
    directionFor: directionFor,
    isDirection: isDirection,
    distanceRange: distanceRange,
    midpointYards: midpointYards,
    destinationPoint: destinationPoint,
    distanceMeters: distanceMeters,
    initialBearing: initialBearing,
    estimateSightingLocation: estimateSightingLocation,
    uncertaintySector: uncertaintySector,
    rayToRectEdge: rayToRectEdge,
    uuid: uuid,
    isUuid: isUuid,
    isIsoTimestamp: isIsoTimestamp,
    nowIso: nowIso,
    localDateKey: localDateKey,
    localDayBounds: localDayBounds,
    deerLabel: deerLabel,
    deerCounts: deerCounts,
    groupType: groupType,
    totalOf: totalOf,
    normalizeSighting: normalizeSighting,
    COUNT_FIELDS: COUNT_FIELDS,
    TYPE_NAMES: TYPE_NAMES,
    weatherCodeText: weatherCodeText,
    pickWeather: pickWeather,
    validateStand: validateStand,
    validateSession: validateSession,
    validateSighting: validateSighting,
    validateGunshot: validateGunshot,
    buildSession: buildSession,
    buildSighting: buildSighting,
    buildGunshot: buildGunshot,
    toServer: toServer,
    buildExport: buildExport,
    validateImport: validateImport,
    timeline: timeline
  };
});
