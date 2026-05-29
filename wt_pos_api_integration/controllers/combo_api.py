import json
import jwt
import logging
from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)


class ComboProductAPI(http.Controller):
    """Controller for combo product endpoints."""

    @http.route([
        '/api/combo/product',
        '/api/combo/product/<int:product_id>'
    ], type='http', auth='public', methods=['GET'], csrf=False)
    def get_combo_product(self, product_id=None, **kwargs):
        """
        Get combo product details including all combinations.
        
        Requires:
        - Authorization: Bearer <JWT_TOKEN> header
        
        URL Parameters:
        - product_id: The product template or product ID
        
        Response (200):
        {
            "status": "success",
            "product_id": 45,
            "product_name": "Combo Meal",
            "base_price": 500.0,
            "combinations": [
                {
                    "combo_id": 10,
                    "combo_name": "Main Course",
                    "product_id": 46,
                    "product_name": "Burger",
                    "qty": 1,
                    "price": 300.0,
                    "extra_price": 50.0
                }
            ]
        }
        
        Returns:
        - 200: Success with combo details
        - 400: Invalid product_id or validation error
        - 401: Unauthorized (invalid/missing token)
        - 404: Product not found or not a combo
        - 500: Server error
        """
        
        # ── Enforce JWT authentication ───────────────────────────────────────
        # SECURITY: Always validate token first
        auth_header = request.httprequest.headers.get('Authorization', '')
        
        if not auth_header.startswith('Bearer '):
            _logger.warning(
                'Missing or invalid Authorization header for combo product from IP: %s',
                request.httprequest.remote_addr,
            )
            return self._json_response(
                status='error',
                message='Missing or invalid Authorization header. Use: Authorization: Bearer <token>',
                code=401  # ⚠️ FIXED: Was 404 (wrong status code)
            )

        token = auth_header.split('Bearer ')[1]
        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            payload = jwt.decode(token, secret, algorithms=['HS256'])
            user_id = payload.get('user_id')
            user = request.env['res.users'].sudo().browse(user_id)

            if not user.exists():
                _logger.warning(
                    'JWT token with invalid user_id (%s) for combo product from IP: %s',
                    user_id,
                    request.httprequest.remote_addr,
                )
                return self._json_response(
                    status='error',
                    message='Invalid token. Please authenticate again.',
                    code=401
                )

            request.update_env(user=user)
            
        except jwt.ExpiredSignatureError:
            _logger.warning(
                'Expired JWT token used for combo product from IP: %s',
                request.httprequest.remote_addr,
            )
            return self._json_response(
                status='error',
                message='Token has expired. Please authenticate again.',
                code=401  # ⚠️ FIXED: Was 404 (wrong status code)
            )
        except jwt.InvalidTokenError as e:
            _logger.warning(
                'Invalid JWT token for combo product from IP: %s: %s',
                request.httprequest.remote_addr,
                str(e),
            )
            return self._json_response(
                status='error',
                message='Invalid token. Please authenticate again.',
                code=401  # ⚠️ FIXED: Was 404 (wrong status code)
            )
        except Exception as e:
            _logger.error(
                'Authentication error for combo product from IP: %s: %s',
                request.httprequest.remote_addr,
                str(e),
            )
            return self._json_response(
                status='error',
                message='Authentication failed. Please try again.',
                code=401  # ⚠️ FIXED: Was 404 (wrong status code)
            )

        # If no product_id provided
        if not product_id:
            _logger.warning(
                'Missing product_id for combo product request from IP: %s',
                request.httprequest.remote_addr,
            )
            return self._json_response(
                status='error',
                message='Product ID is required',
                code=400  # ⚠️ FIXED: Was 404 (validation error should be 400)
            )

        try:
            # Fetch the product from product.template, fallback to product.product
            product = request.env['product.template'].sudo().browse(product_id)
            if not product.exists():
                product = request.env['product.product'].sudo().browse(product_id)
            
            if not product.exists():
                _logger.warning(
                    'Product not found: %d from IP: %s',
                    product_id,
                    request.httprequest.remote_addr,
                )
                return self._json_response(
                    status='error',
                    message=f'Product {product_id} not found',
                    code=404
                )

            # Ensure the product type is 'combo'
            is_combo = False
            if 'type' in product._fields and product.type == 'combo':
                is_combo = True
            elif 'detailed_type' in product._fields and product.detailed_type == 'combo':
                is_combo = True

            if not is_combo:
                _logger.warning(
                    'Non-combo product requested: %d from IP: %s',
                    product_id,
                    request.httprequest.remote_addr,
                )
                return self._json_response(
                    status='error',
                    message='Product is not a combo product',
                    code=400  # ⚠️ FIXED: Was 404 (validation error should be 400)
                )

            combinations = []
            
            # Check if the product has combo_ids
            if 'combo_ids' in product._fields and product.combo_ids:
                for combo in product.combo_ids:
                    if 'combo_item_ids' in combo._fields:
                        for line in combo.combo_item_ids:
                            if 'product_id' not in line._fields or not line.product_id:
                                continue
                                
                            combo_item = line.product_id

                            # Try to extract quantity, fallback to 1
                            qty = 1
                            if 'combo_qty' in line._fields:
                                qty = line.combo_qty
                            elif 'qty' in line._fields:
                                qty = line.qty

                            # Extract original price (lst_price)
                            price = 0.0
                            if 'lst_price' in line._fields:
                                price = line.lst_price
                            elif 'lst_price' in combo_item._fields:
                                price = combo_item.lst_price

                            # Extract extra price for the combo
                            extra_price = 0.0
                            if 'extra_price' in line._fields:
                                extra_price = line.extra_price
                            elif 'combo_price' in line._fields:
                                extra_price = line.combo_price

                            qty_available = 0.0
                            is_storable = True
                            try:
                                qty_available = float(combo_item.qty_available or 0)
                                if 'is_storable' in combo_item._fields:
                                    is_storable = bool(combo_item.is_storable)
                                elif combo_item.product_tmpl_id and 'is_storable' in combo_item.product_tmpl_id._fields:
                                    is_storable = bool(combo_item.product_tmpl_id.is_storable)
                                else:
                                    product_type = (
                                        getattr(combo_item, 'type', '')
                                        or getattr(combo_item, 'detailed_type', '')
                                        or getattr(combo_item.product_tmpl_id, 'type', '')
                                        or getattr(combo_item.product_tmpl_id, 'detailed_type', '')
                                    )
                                    is_storable = product_type in ('product', 'consu')
                            except Exception:
                                qty_available = 0.0
                                is_storable = True

                            combinations.append({
                                'combo_id': combo.id,
                                'combo_name': combo.name,
                                'product_id': combo_item.id,
                                'product_name': combo_item.name,
                                'qty': qty,
                                'price': price,
                                'extra_price': extra_price,
                                'qty_available': qty_available,
                                'is_storable': is_storable
                            })

            # Extract main product price
            product_price = 0.0
            if 'list_price' in product._fields:
                product_price = product.list_price
            elif 'lst_price' in product._fields:
                product_price = product.lst_price

            response_data = {
                'product_id': product.id,
                'product_name': product.display_name or product.name,
                'base_price': product_price,
                'combinations': combinations
            }
            
            _logger.info(
                'Retrieved combo product %d with %d combinations for user from IP: %s',
                product.id,
                len(combinations),
                request.httprequest.remote_addr,
            )
            
            return self._json_response(
                status='success',
                data=response_data,
                code=200
            )

        except Exception as e:
            _logger.error(
                'Error fetching combo product %d: %s from IP: %s',
                product_id,
                str(e),
                request.httprequest.remote_addr,
            )
            return self._json_response(
                status='error',
                message='An error occurred while fetching combo details',
                code=500
            )

    # ──────────────────────────────────────────────────────────────────────────
    # HELPER: Standard JSON response with proper status codes
    # ──────────────────────────────────────────────────────────────────────────
    def _json_response(self, status="success", data=None, message="", code=200):
        """
        Return standard JSON response.
        
        Args:
            status: "success" or "error"
            data: Response data (dict or other)
            message: Optional message
            code: HTTP status code
        
        Returns:
            HTTP response with JSON body
        """
        response_dict = {
            "status": status,
        }
        
        # Flatten dictionary data into the root of the JSON response
        if data:
            if isinstance(data, dict):
                response_dict.update(data)
            else:
                response_dict["data"] = data
        elif status == "success" and data is not None:
            # If data is literally passed as an empty list (e.g. data=[])
            response_dict["data"] = data

        if message:
            response_dict["message"] = message
        if code and code != 200:
            response_dict["code"] = code

        return request.make_response(
            json.dumps(response_dict, indent=2),
            headers=[('Content-Type', 'application/json')],
            status=code
        )
