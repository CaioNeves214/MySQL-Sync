# -*- coding: utf-8 -*-
import mysql.connector
from flask import Flask, request, jsonify
from config import Config

app = Flask(__name__)

# Valida se as variavies de ambiente obrigatorias estao carregadas
Config.validate()

def get_db_connection():
    """Retorna uma conexão com o banco de dados centralizado."""
    # Desempacotamento de dicionário (**) conforme o guia do projeto
    # O guia exige o uso de ** para passar os argumentos de conexão
    return mysql.connector.connect(**Config.DB_CONFIG)

@app.route('/federated/sincronizar', methods=['POST'])
def sincronizar():
    """
    RECEBIMENTO DE DADOS SINCRONIZADOS
    Valida token, recebe payload JSON e insere de forma idempotente.
    """
    
    # 1. Autenticação: Header X-API-Token obrigatorio
    token = request.headers.get('X-API-Token')
    if not token or token != Config.API_TOKEN:
        # 401: Nao autorizado conforme contrato de API
        return jsonify({"erro": "Nao autorizado"}), 401

    # 2. Carrega corpo da requisição
    data = request.get_json()
    if not data:
        # 400: Mal-formatado
        return jsonify({"erro": "JSON invalido ou ausente"}), 400

    host_origem = data.get('host_origem')
    registros = data.get('registros')

    # 3. Validação básica de campos obrigatórios
    if not host_origem or not isinstance(registros, list):
        # 400: Erro de payload
        return jsonify({"erro": "host_origem e registros sao obrigatorios"}), 400

    conn = None
    inseridos = 0
    ignorados = 0

    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # QUERY: Idempotência com INSERT IGNORE. Crucial para evitar duplicatas
        # A chave única no banco (host_origem, ID_LOGUSUARIO_origem) garante a integridade.
        query = """
            INSERT IGNORE INTO log_usuario_servidor (
                host_origem, ID_LOGUSUARIO_origem, ID_USUARIO, ID_EMPRESA, 
                TEXTO, DT_LOGUSUARIO, HR_LOGUSUARIO, TIPO, TABELA, CHAVE_PRIMARIA
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """

        # LOOP: Itera sobre registros para inserção um a um (ou em lote se preferir)
        for reg in registros:
            # TEXTO (BLOB) é enviado como string e aceito pelo connector
            valores = (
                host_origem,
                reg.get('ID_LOGUSUARIO'),
                reg.get('ID_USUARIO'),
                reg.get('ID_EMPRESA'),
                reg.get('TEXTO'), 
                reg.get('DT_LOGUSUARIO'),
                reg.get('HR_LOGUSUARIO'),
                reg.get('TIPO', 0),
                reg.get('TABELA'),
                reg.get('CHAVE_PRIMARIA')
            )
            
            cursor.execute(query, valores)
            
            # MySQL Connector: rowcount > 0 se inserido, 0 se ignorado pelo INSERT IGNORE
            if cursor.rowcount > 0:
                inseridos += 1
            else:
                ignorados += 1

        # Confirma as alterações no banco de dados
        conn.commit()
        
        # 4. Resposta de sucesso (HTTP 200) com métricas de sincronização
        return jsonify({
            "status": "ok",
            "inseridos": inseridos,
            "ignorados": ignorados
        }), 200

    except mysql.connector.Error as err:
        # Erro de banco de dados (500)
        # Nota: f-strings nao existem no Python 2.7 — usamos .format() aqui
        return jsonify({"erro": "Erro banco: {0}".format(str(err))}), 500

    except Exception as e:
        # Erro inesperado
        return jsonify({"erro": "Erro interno: {0}".format(str(e))}), 500

    finally:
        # Garante que a conexão sempre seja fechada
        if conn:
            conn.close()

if __name__ == '__main__':
    # Nota: Em producao, nao use o servidor de desenvolvimento do Flask.
    # Use Gunicorn ou outro servidor WSGI, e HTTPS via porta 443 (Nginx/Reverse Proxy).
    app.run(debug=True, host='0.0.0.0', port=5000)
