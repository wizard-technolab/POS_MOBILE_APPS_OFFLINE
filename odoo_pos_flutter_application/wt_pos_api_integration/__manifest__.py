# -*- coding: utf-8 -*-
# pylint: disable=missing-module-docstring

{
    'name': 'POS API Integration',
    'version': '19.0.1.0.0',
    'category': 'Sales/Point of Sale',
    'summary': 'Integration for POS API with Branch, Device and Subscription License management',
    'author': 'Warlock Technologies, Odoo Community Association (OCA)',
    'website': 'https://www.warlocktechnologies.com',

    'depends': ['base','point_of_sale'],
    'data': [             
    
        'security/ir.model.access.csv',
        'views/device_branch_views.xml',
        'views/device_device_views.xml',
        'views/sync_log_views.xml',
        'views/subscription_views.xml',
    ],
    'application': True,
    'license': 'LGPL-3',
    'external_dependencies': {
        'python': ['jwt'],
    },
}
