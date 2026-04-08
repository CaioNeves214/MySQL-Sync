# -*- coding: utf-8 -*-
# from __future__ garante que print() seja uma funcao no Python 2.7,
# mantendo compatibilidade total com Python 2.7 e 3.x simultaneamente.
from __future__ import print_function
import os
from dotenv import load_dotenv

# Carrega variaveis de ambiente
load_dotenv()

class Config:
    """Configurações da API carregadas do ambiente."""
    
    # Configuração do Banco de Dados conforme aiguide.md
    DB_CONFIG = {
        'host': os.getenv('DB_HOST', 'localhost'),
        'user': os.getenv('DB_USER'),
        'password': os.getenv('DB_PASSWORD'),
        'database': os.getenv('DB_DATABASE')
    }
    
    # Token de segurança para autenticacao
    API_TOKEN = os.getenv('API_TOKEN')

    @staticmethod
    def validate():
        """Valida se as configurações críticas estão presentes."""
        required = ['DB_USER', 'DB_PASSWORD', 'DB_DATABASE', 'API_TOKEN']
        missing = [var for var in required if not os.getenv(var)]
        if missing:
            # f-strings nao existem no Python 2.7 — usamos .format()
            print("AVISO: Variaveis de ambiente faltando: {0}".format(', '.join(missing)))
        return not bool(missing)