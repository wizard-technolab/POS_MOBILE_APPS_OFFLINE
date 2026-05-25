import json
import jwt
from odoo import http
from odoo.http import request, Response

class ComboProductAPI(http.Controller):

    @http.route([
        '/api/combo/product',
        '/api/combo/product/<int:product_id>'
    ], type='http', auth='public', methods=['GET'], csrf=False)
    def get_combo_product(self, product_id=None, **kwargs):
        # Enforce JWT authentication
        auth_header = request.httprequest.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return self._json_response(status='error', message='Missing or invalid Authorization header (Bearer token required).', code=404)

        token = auth_header.split('Bearer ')[1]
        try:
            secret = request.env['jwt.config'].sudo().get_secret_key()
            jwt.decode(token, secret, algorithms=['HS256'])
        except jwt.ExpiredSignatureError:
            return self._json_response(status='error', message='Token has expired.', code=404)
        except jwt.InvalidTokenError:
            return self._json_response(status='error', message='Invalid token.', code=404)
        except Exception as e:
            return self._json_response(status='error', message=f'Authentication error: {str(e)}', code=404)

        # If no product_id provided
        if not product_id:
            return self._json_response(status='error', message='No product_id provided', code=404)

        try:
            # Fetch the product from product.template, fallback to product.product
            product = request.env['product.template'].sudo().browse(product_id)
            if not product.exists():
                product = request.env['product.product'].sudo().browse(product_id)
            
            if not product.exists():
                return self._json_response(status='error', message='Product not found', code=404)

            # Ensure the product type is 'combo'
            is_combo = False
            if 'type' in product._fields and product.type == 'combo':
                is_combo = True
            elif 'detailed_type' in product._fields and product.detailed_type == 'combo':
                is_combo = True

            if not is_combo:
                return self._json_response(status='error', message='Product is not a combo product', code=404)

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

                            combinations.append({
                                'combo_id': combo.id,
                                'combo_name': combo.name,
                                'product_id': combo_item.id,
                                'product_name': combo_item.name,
                                'qty': qty,
                                'price': price,
                                'extra_price': extra_price
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
            return self._json_response(status='success', data=response_data, code=200)

        except Exception as e:
            return self._json_response(status='error', message=f'An error occurred while fetching combo details: {str(e)}', code=500)

    def _json_response(self, status="success", data=None, message="", code=200):
        """Return standard JSON response."""
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
