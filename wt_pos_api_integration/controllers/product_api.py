# ─────────────────────────────────────────────────────────────
# product_api.py
#
# PURPOSE:
#   When the Flutter app selects a POS Session from Settings,
#   the product list must show ONLY the products available in
#   that session's POS config — same as what Odoo POS itself shows.
#
# KEY FIX:
#   session_id param is now REQUIRED (not optional).
#   Products are filtered by the session's allowed POS categories
#   (iface_available_categ_ids on pos.config).
#   If no categories are restricted, all available_in_pos products
#   are returned (same as Odoo default behaviour).
#
# IMAGE SUPPORT ADDED:
#   Each product now includes an 'image' field containing the
#   product image encoded as a base64 string (data:image/png;base64,...).
#   Flutter app reads this base64 string and displays it as a widget.
#   Uses Odoo's 'image_512' field (512x512px) for crisp display on mobile.
#   Previously used image_128 (128x128px) which caused blur when enlarged.
# ─────────────────────────────────────────────────────────────

import json
import base64
import jwt
import logging
from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)


class ProductAPIController(http.Controller):

    # ──────────────────────────────────────────────────────────
    # HELPER: Validate JWT Bearer token
    # ──────────────────────────────────────────────────────────
    def _validate_token(self):
        """Validate the JWT Bearer token and switch request env to that user."""
        auth = request.httprequest.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            _logger.warning(
                'Missing or invalid Authorization header for %s from IP: %s',
                request.httprequest.path,
                request.httprequest.remote_addr,
            )
            return False

        token = auth[7:]
        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            payload = jwt.decode(token, secret, algorithms=['HS256'])
            user_id = payload.get('user_id')
            user = request.env['res.users'].sudo().browse(user_id)

            if not user.exists():
                _logger.warning(
                    'JWT token with invalid user_id (%s) for %s from IP: %s',
                    user_id,
                    request.httprequest.path,
                    request.httprequest.remote_addr,
                )
                return False

            request.update_env(user=user)
            return True

        except jwt.ExpiredSignatureError:
            _logger.warning(
                'Expired JWT token used for %s from IP: %s',
                request.httprequest.path,
                request.httprequest.remote_addr,
            )
            return False
        except jwt.InvalidTokenError as exc:
            _logger.warning(
                'Invalid JWT token for %s from IP: %s: %s',
                request.httprequest.path,
                request.httprequest.remote_addr,
                exc,
            )
            return False
        except Exception as exc:  # pylint: disable=broad-except
            _logger.exception(
                'JWT validation error for %s from IP: %s: %s',
                request.httprequest.path,
                request.httprequest.remote_addr,
                exc,
            )
            return False

    # ──────────────────────────────────────────────────────────
    # HELPER: Write a sync log entry
    # ──────────────────────────────────────────────────────────
    def _log(self, payload, response, status):
        try:
            request.env['sync.log'].sudo().create({
                'endpoint': request.httprequest.path,
                'method':   request.httprequest.method,
                'payload':  json.dumps(payload, indent=4),
                'response': json.dumps(response, indent=4),
                'status':   status,
            })
        except Exception:
            pass  # Never break the main flow because of logging

    # ──────────────────────────────────────────────────────────
    # HELPER: Build combo group data for one product template
    #
    # Odoo POS combo structure:
    #   product.template
    #       └─ combo_ids  (Many2many) → pos.combo  ← "group" e.g. "Choose Burger"
    #               └─ combo_line_ids (One2many) → pos.combo.line ← one choice
    #                       ├─ product_id
    #                       └─ combo_price  (extra charge for this choice)
    # ──────────────────────────────────────────────────────────
    def _get_combo_groups(self, product_template):
        groups = []
        combos = getattr(product_template, 'combo_ids', None)
        if not combos:
            return groups

        for combo in combos:
            choices = []
            lines = getattr(combo, 'combo_item_ids', None) or getattr(combo, 'combo_line_ids', [])
            for line in lines:
                # Odoo 17 uses 'combo_price'; Odoo 16 may use 'extra_price'
                extra = 0.0
                if hasattr(line, 'combo_price') and line.combo_price:
                    extra = float(line.combo_price)
                elif hasattr(line, 'extra_price') and line.extra_price:
                    extra = float(line.extra_price)

                # Stock info belongs to the product.product assigned on the combo line,
                # not to the combo product itself.
                choice_qty = 0.0
                choice_is_storable = True
                try:
                    combo_product = line.product_id
                    choice_qty = float(combo_product.qty_available or 0)

                    # In Odoo 18 this flag is usually available on the template.
                    # Keep fallbacks so the API works across product.product/template shapes.
                    if 'is_storable' in combo_product._fields:
                        choice_is_storable = bool(combo_product.is_storable)
                    elif combo_product.product_tmpl_id and 'is_storable' in combo_product.product_tmpl_id._fields:
                        choice_is_storable = bool(combo_product.product_tmpl_id.is_storable)
                    else:
                        product_type = (
                            getattr(combo_product, 'type', '')
                            or getattr(combo_product, 'detailed_type', '')
                            or getattr(combo_product.product_tmpl_id, 'type', '')
                            or getattr(combo_product.product_tmpl_id, 'detailed_type', '')
                        )
                        choice_is_storable = product_type in ('product', 'consu')
                except Exception:
                    choice_qty = 0.0
                    choice_is_storable = True

                choices.append({
                    'product_id':    line.product_id.id,
                    'product_name':  line.product_id.name or '',
                    'extra_price':   extra,
                    'qty_available': choice_qty,
                    'is_storable':   choice_is_storable,
                })

            # qty_min / qty_max live on pos.combo (the group level)
            min_qty = int(combo.qty_min) if getattr(combo, 'qty_min', None) else 1
            max_qty = int(combo.qty_max) if getattr(combo, 'qty_max', None) else 1

            groups.append({
                'group_id':   combo.id,
                'group_name': combo.name or '',
                'min_qty':    min_qty,
                'max_qty':    max_qty,
                'choices':    choices,
            })

        return groups

    # ──────────────────────────────────────────────────────────
    # HELPER: Build the product search domain for a given session
    #
    # WHY THIS EXISTS:
    #   The Flutter app lets the cashier pick a POS Session from Settings.
    #   After that, both the Product Screen and the Order creation must
    #   use products from THAT session's config — not from every session.
    #
    # HOW IT WORKS:
    #   1. Start with base domain: sale_ok=True, active=True, available_in_pos=True
    #   2. If a session_id is provided, look up its pos.config
    #   3. If the pos.config has category restrictions (iface_available_categ_ids),
    #      add a domain filter so only products in those categories are returned.
    #   4. This matches exactly what Odoo POS UI shows to the cashier.
    # ──────────────────────────────────────────────────────────
    def _build_product_domain(self, session_id, active=True):
        """
        Returns (domain, error_message).
        domain  = list of Odoo search domain tuples
        error_message = None if OK, string if the session is invalid
        """
        # Base domain: only POS-available, saleable, active products
        domain = [
            ('sale_ok',          '=', True),
            ('active',           '=', active),
            ('available_in_pos', '=', True),
        ]

        if not session_id:
            # No session selected — return all POS products (fallback behaviour)
            return domain, None

        # Validate the session exists and is still open
        session = request.env['pos.session'].sudo().browse(session_id)
        if not session.exists():
            return None, f'POS Session {session_id} does not exist.'
        if session.state != 'opened':
            return None, (
                f'POS Session "{session.name}" is {session.state}, not open. '
                'Please select an open session in Settings.'
            )

        pos_config = session.config_id

        # Check if the POS config restricts products by category
        # iface_available_categ_ids = POS categories allowed in this config
        # If empty → no restriction → all available_in_pos products shown
        categ_ids = getattr(pos_config, 'iface_available_categ_ids', None)
        if categ_ids and categ_ids.ids:
            # Filter: product must belong to at least one of the allowed POS categories
            domain.append(('pos_categ_ids', 'in', categ_ids.ids))

        return domain, None

    # ──────────────────────────────────────────────────────────
    # HELPER: Convert Odoo binary image field to base64 data URI
    #
    # WHY base64:
    #   Flutter can decode a base64 string directly using
    #   base64Decode() and display it with Image.memory().
    #   No separate image URL / authentication needed.
    #
    # image_128 = Odoo's 128x128 px thumbnail — small size,
    #   fast to transfer, good enough for a product grid card.
    #   If you want higher resolution change to 'image_256' or 'image_512'.
    # ──────────────────────────────────────────────────────────
    def _strip_html(self, html_text):
        """Remove HTML tags from Odoo rich text fields — returns plain text."""
        if not html_text:
            return ''
        try:
            import re
            clean = re.sub(r'<[^>]+>', '', str(html_text))
            clean = clean.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>') \
                         .replace('&quot;', '"').replace('&#39;', "'").replace('&nbsp;', ' ')
            return clean.strip()
        except Exception:
            return str(html_text) if html_text else ''

    def _get_product_image_base64(self, product_template):
        """
        Returns a base64 data URI string like:
            'data:image/png;base64,iVBORw0KGgo...'
        or None if the product has no image.

        Uses image_1920 (full resolution original) for best quality.
        Falls back to image_512 if image_1920 is not available.
        """
        try:
            # image_1920: full resolution original image uploaded by user.
            # Best quality — no blur at any screen size.
            # Fallback to image_512 if image_1920 is not set.
            raw = product_template.image_1920 or product_template.image_512
            if not raw:
                return None

            if isinstance(raw, bytes):
                img_base64 = raw.decode('utf-8')
            else:
                img_base64 = base64.b64encode(raw).decode('utf-8')

            return f'data:image/png;base64,{img_base64}'
        except Exception:
            return None

    # ──────────────────────────────────────────────────────────
    # HELPER: Build variant list for a product template
    #
    # Odoo variant structure:
    #   product.template
    #       └─ product_variant_ids (One2many) → product.product
    #               └─ product_template_attribute_value_ids
    #                       ├─ attribute_id  (e.g. "Color")
    #                       └─ product_attribute_value_id  (e.g. "Red")
    #
    # We return one record per active product.product variant with:
    #   variant_id   → product.product ID (used as cart item key in Flutter)
    #   price        → lst_price (includes any attribute price_extra)
    #   attributes   → list of {attribute_id, attribute_name, value_id, value_name}
    #
    # Flutter uses this to render attribute chip selectors in the popup.
    # When the user picks a combo of values, we match the variant_id and
    # add THAT id (not the template id) to the cart so each variant is a
    # separate line item — identical to standard Odoo POS behaviour.
    # ──────────────────────────────────────────────────────────
    def _get_product_variants(self, product_template):
        """
        Returns a list of variant dicts for templates that have >1 active variant.
        Returns [] for single-variant (no-attribute) products.
        """
        variants = []
        for variant in product_template.product_variant_ids:
            # Skip archived variants
            if not variant.active:
                continue

            # Collect attribute values for this specific variant
            attributes = []
            for ptav in variant.product_template_attribute_value_ids:
                attributes.append({
                    'attribute_id':   ptav.attribute_id.id,
                    'attribute_name': ptav.attribute_id.name or '',
                    # value_id / value_name from the attribute value record
                    'value_id':   ptav.product_attribute_value_id.id,
                    'value_name': ptav.product_attribute_value_id.name or '',
                    # price_extra: surcharge for this attribute value
                    # e.g. +2.00 for "2XL" — Flutter shows "+$2.00" on chips
                    'price_extra': float(ptav.price_extra or 0.0),
                })

            # lst_price on product.product already includes price_extra from
            # attribute values (e.g. +5 for "XL" size) — use it directly.
            try:
                variant_price = float(variant.lst_price)
            except Exception:
                variant_price = float(product_template.list_price)

            # Variant image: use image_1920 (full resolution) for crisp display.
            # Falls back to image_512 if image_1920 is not set on the variant.
            variant_image = None
            try:
                raw = variant.image_1920 or variant.image_512
                if raw:
                    if isinstance(raw, bytes):
                        img_b64 = raw.decode('utf-8')
                    else:
                        img_b64 = base64.b64encode(raw).decode('utf-8')
                    variant_image = f'data:image/png;base64,{img_b64}'
            except Exception:
                pass  # Will fall back to template image on Flutter side

            # Tax: product.product inherits taxes_id from its template.
            # We read it here so Flutter can show per-variant GST badge.
            variant_taxes = []
            try:
                for tax in variant.taxes_id:
                    variant_taxes.append({
                        'id':     tax.id,
                        'name':   tax.name or '',
                        'amount': float(tax.amount),
                    })
            except Exception:
                pass

            # ✅ NEW: qty_available per variant
            try:
                variant_qty = float(variant.qty_available or 0)
            except Exception:
                variant_qty = 0.0

            variants.append({
                'variant_id':     variant.id,
                'variant_name':   variant.display_name or variant.name or '',
                'price':          variant_price,
                'image':          variant_image,
                'attributes':     attributes,
                'tax_id':         variant_taxes,
                'qty_available':  variant_qty,
            })

        return variants

    # ──────────────────────────────────────────────────────────
    # CORS preflight for browser clients
    # ──────────────────────────────────────────────────────────
    @http.route('/api/products', type='http', auth='public',
                methods=['OPTIONS'], csrf=False)
    def products_options(self, **kwargs):
        return request.make_response('', headers=[
            ('Access-Control-Allow-Origin',  '*'),
            ('Access-Control-Allow-Headers', 'Authorization, Content-Type'),
            ('Access-Control-Allow-Methods', 'GET, OPTIONS'),
        ], status=204)

    # ──────────────────────────────────────────────────────
    # GET /api/products — NOW INCLUDES qty_available
    #
    # Query params:
    #   session_id     (int)  — REQUIRED: the POS session selected in Settings
    #   limit          (int)  — max records, default 100, max 500
    #   offset         (int)  — for pagination
    #   active         (bool) — default true
    #   include_combos (bool) — include combo group data, default false
    #
    # BEHAVIOUR:
    #   Returns the same product list that Odoo POS shows for the selected session.
    #   If the POS config has no category restrictions, all POS products are returned.
    #
    # RESPONSE SHAPE (each product):
    #   {
    #     "id": 42,
    #     "name": "Classic T-Shirt",
    #     "price": 25.0,
    #     "tax_id": [...],
    #     "category": "All / Saleable",
    #     "pos_category": ["Upper body"],
    #     "active": true,
    #     "is_combo": false,
    #     "combo_groups": [],
    #     "image": "data:image/png;base64,iVBORw0...",
    #     "qty_available": 15.0   ← NEW: stock quantity from Odoo
    #   }
    # ──────────────────────────────────────────────────────────
    @http.route('/api/products', type='http', auth='public',
                methods=['GET'], csrf=False)
    def get_products(self, **kwargs):
        limit          = min(int(kwargs.get('limit',  100)), 500)
        offset         = int(kwargs.get('offset', 0))
        active_param   = kwargs.get('active', 'true')
        active         = active_param.lower() != 'false'
        include_combos = kwargs.get('include_combos', 'false').lower() == 'true'

        # session_id: the POS session the cashier selected in Settings
        session_id_raw = kwargs.get('session_id', None)
        session_id     = int(session_id_raw) if session_id_raw else None

        payload_log = {
            'limit': limit, 'offset': offset,
            'active': active, 'include_combos': include_combos,
            'session_id': session_id,
            'ip': request.httprequest.remote_addr,
        }

        # Step 1 — Validate JWT token
        if not self._validate_token():
            res = {'status': 'error', 'message': 'Unauthorized', 'code': 401}
            self._log(payload_log, res, 'error')
            return request.make_response(
                json.dumps(res),
                headers=[('Content-Type', 'application/json')], status=401)

        try:
            # Step 2 — Build search domain filtered by the selected session
            domain, err = self._build_product_domain(session_id, active=active)
            if err:
                res = {'status': 'error', 'message': err, 'code': 400}
                self._log(payload_log, res, 'error')
                return request.make_response(
                    json.dumps(res),
                    headers=[('Content-Type', 'application/json')], status=400)

            # Step 3 — Fetch matching products
            # NOTE: We no longer use search_read here because we need to call
            # browse() on templates anyway to access image_128 (binary field).
            # search_read does not return binary fields properly.
            product_ids = request.env['product.template'].sudo().search(
                domain,
                limit=limit,
                offset=offset,
                order='id asc',
            )

            if not product_ids:
                res = {'status': 'success', 'data': [], 'message': '', 'code': 200}
                return request.make_response(
                    json.dumps(res),
                    headers=[('Content-Type', 'application/json')], status=200)

            # Step 4 — Read scalar fields using search_read (fast, single query)
            products = request.env['product.template'].sudo().search_read(
                domain=[('id', 'in', product_ids.ids)],
                fields=['id', 'name', 'list_price', 'taxes_id',
                        'categ_id', 'pos_categ_ids', 'active', 'is_storable'],
                order='id asc',
            )

            # Fetch qty_available for each product (primary variant)
            qty_map = {}
            for template_id in product_ids.ids:
                variants = request.env['product.product'].sudo().search(
                    [('product_tmpl_id', '=', template_id), ('active', '=', True)],
                    limit=1,
                )
                if variants:
                    qty_map[template_id] = float(variants[0].qty_available or 0)
                else:
                    qty_map[template_id] = 0.0

            # Batch load product templates WITH image + description + optional products
            tmpl_objects = request.env['product.template'].sudo().browse(product_ids.ids)
            # Build a dict: product_id → template ORM object for O(1) lookup below
            tmpl_map = {t.id: t for t in tmpl_objects}

            # Step 6 — Batch load internal product categories (avoid N+1 queries)
            categ_ids = list({p['categ_id'][0] for p in products if p.get('categ_id')})
            categ_map = {}
            if categ_ids:
                categories = request.env['product.category'].sudo().search_read(
                    domain=[('id', 'in', categ_ids)],
                    fields=['id', 'complete_name'],
                )
                categ_map = {c['id']: c['complete_name'] for c in categories}

            # Step 7 — Batch load POS categories for each product
            all_pos_categ_ids = list(
                {cid for p in products for cid in (p.get('pos_categ_ids') or [])}
            )
            pos_categ_map = {}
            if all_pos_categ_ids:
                pos_categs = request.env['pos.category'].sudo().search_read(
                    domain=[('id', 'in', all_pos_categ_ids)],
                    fields=['id', 'name'],
                )
                pos_categ_map = {c['id']: c['name'] for c in pos_categs}

            # Step 8 — Batch load taxes
            all_tax_ids = list({tid for p in products for tid in p.get('taxes_id', [])})
            tax_map = {}
            if all_tax_ids:
                taxes = request.env['account.tax'].sudo().search_read(
                    domain=[('id', 'in', all_tax_ids)],
                    fields=['id', 'name', 'amount'],
                )
                tax_map = {t['id']: {'id': t['id'], 'name': t['name'], 'amount': t['amount']} for t in taxes}

            # Load full template objects if combo data is needed
            template_map = {}
            if include_combos:
                tmpl_ids = [p['id'] for p in products]
                templates = request.env['product.template'].sudo().browse(tmpl_ids)
                template_map = {t.id: t for t in templates}

            # Build response list
            result = []
            for p in products:
                # Internal product category (e.g. "All / Saleable")
                category = (categ_map.get(p['categ_id'][0], '')
                            if p.get('categ_id') else '')

                # POS category list (e.g. ["Upper body", "Lower body"])
                pos_categs = [
                    pos_categ_map[cid]
                    for cid in (p.get('pos_categ_ids') or [])
                    if cid in pos_categ_map
                ]

                # Taxes
                taxes = [tax_map[t] for t in p.get('taxes_id', []) if t in tax_map]

                # Combo data (only if include_combos=true was requested)
                is_combo     = False
                combo_groups = []
                if include_combos and p['id'] in template_map:
                    tmpl     = template_map[p['id']]
                    product_type = getattr(tmpl, 'type', '') or getattr(tmpl, 'detailed_type', '')
                    is_combo     = (product_type == 'combo')
                    if is_combo:
                        combo_groups = self._get_combo_groups(tmpl)

                # ── IMAGE ──────────────────────────────────────────────────
                # Fetch the product image as a base64 data URI string.
                # tmpl_map[p['id']] already holds the ORM record (browsed above).
                # _get_product_image_base64 reads image_128 and converts to
                # "data:image/png;base64,..." that Flutter can decode directly.
                image_base64 = None
                if p['id'] in tmpl_map:
                    image_base64 = self._get_product_image_base64(tmpl_map[p['id']])
                # ──────────────────────────────────────────────────────────

                # ── VARIANTS ───────────────────────────────────────────────
                # Fetch product.product records for this template.
                # has_variants = True  → Flutter shows attribute selectors in popup.
                # has_variants = False → Flutter behaves as before (no selector).
                #
                # We only fetch variants when the template has >1 active variant
                # to avoid the extra ORM calls for simple single-variant products.
                variants_data = []
                has_variants  = False
                if p['id'] in tmpl_map:
                    tmpl_obj      = tmpl_map[p['id']]
                    active_count  = sum(1 for v in tmpl_obj.product_variant_ids if v.active)
                    if active_count > 1:
                        has_variants  = True
                        variants_data = self._get_product_variants(tmpl_obj)

                # QTY_AVAILABLE
                qty_available = qty_map.get(p['id'], 0.0)

                # ✅ NEW: Public Description
                public_description = ''
                if p['id'] in tmpl_map:
                    tmpl_obj = tmpl_map[p['id']]
                    desc = getattr(tmpl_obj, 'public_description', None)
                    if desc:
                        # public_description can be HTML in Odoo; send as-is
                        # Flutter will strip tags or render accordingly
                        public_description = str(desc) if desc else ''

                # ✅ NEW: Optional Products (pos_optional_product_ids)
                optional_product_ids = []
                if p['id'] in tmpl_map:
                    tmpl_obj = tmpl_map[p['id']]
                    opt_products = getattr(tmpl_obj, 'pos_optional_product_ids', None)
                    if opt_products:
                        optional_product_ids = opt_products.ids

                result.append({
                    'id':                    p['id'],
                    'name':                  p['name'],
                    'price':                 p['list_price'],
                    'tax_id':                taxes,
                    'category':              category,
                    'pos_category':          pos_categs,
                    'active':                p['active'],
                    'is_combo':              is_combo,
                    'combo_groups':          combo_groups,
                    'image':                 image_base64,
                    'has_variants':          has_variants,
                    'variants':              variants_data,
                    'qty_available':         qty_available,
                    'is_storable':           bool(p.get('is_storable', False)),
                    'public_description':    public_description,
                    'optional_product_ids':  optional_product_ids,
                })

            self._log(payload_log, result, 'success')
            res = {'status': 'success', 'data': result, 'message': '', 'code': 200}

        except Exception as e:
            res = {
                'status':  'error',
                'message': f'Failed to fetch products: {str(e)}',
                'code':    500,
            }
            self._log(payload_log, res, 'error')

        return request.make_response(
            json.dumps(res),
            headers=[
                ('Content-Type', 'application/json'),
                ('Access-Control-Allow-Origin', '*'),
            ],
        )
