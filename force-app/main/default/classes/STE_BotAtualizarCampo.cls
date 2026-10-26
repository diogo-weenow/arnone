/**
 * Grava a correção de um campo do cadastro feita pelo candidato no assistente.
 *
 * Só mexe no campo que a pessoa escolheu corrigir: a ação é chamada uma vez por
 * correção, e o resto do cadastro fica intacto. Vale para Lead e para Contato,
 * porque STE_BotConsultarCandidato pode achar qualquer um dos dois.
 *
 * O telefone corrigido vai só para MobilePhone. STE_Telefone_E164__c continua
 * sendo o número do WhatsApp de onde a pessoa está falando — é a chave que liga
 * a conversa ao cadastro, e trocá-la por um número informado no chat quebraria
 * o reconhecimento na próxima conversa.
 *
 * O nome completo vai inteiro para LastName, com FirstName limpo, que é a
 * convenção que STE_BotRegistrarCandidato já usa ao criar o Lead. Evita que o
 * mesmo cadastro fique com o nome partido de um jeito por um caminho e de outro
 * jeito pelo outro.
 */
public without sharing class STE_BotAtualizarCampo {
  private static final Integer MINIMO_DIGITOS_TELEFONE = 10;
  private static final Set<String> GENEROS = new Set<String>{
    'Feminino',
    'Masculino',
    'Não binário',
    'Prefiro não informar'
  };

  public class Entrada {
    @InvocableVariable(label='Id do registro')
    public String recordId;

    @InvocableVariable(label='Campo a corrigir (Nome, Email, Telefone ou Genero)')
    public String campo;

    @InvocableVariable(label='Novo valor')
    public String valor;
  }

  public class Resultado {
    @InvocableVariable(label='Sucesso')
    public Boolean sucesso;

    @InvocableVariable(label='Mensagem')
    public String mensagem;

    private Resultado() {
      sucesso = false;
    }
  }

  @InvocableMethod(
    label='Atualizar campo do candidato — Stech Telecom'
    description='Grava a correção de um campo do cadastro do candidato informada no assistente.'
    category='Stech Telecom'
  )
  public static List<Resultado> atualizar(List<Entrada> entradas) {
    List<Resultado> saida = new List<Resultado>();
    if (entradas == null || entradas.isEmpty()) {
      return saida;
    }

    List<SObject> registros = new List<SObject>();
    List<Integer> indices = new List<Integer>();

    for (Integer i = 0; i < entradas.size(); i++) {
      Resultado r = new Resultado();
      saida.add(r);

      Entrada entrada = entradas[i];
      Id registro = idValido(entrada == null ? null : entrada.recordId);
      if (registro == null) {
        r.mensagem = 'Não encontrei seu cadastro para gravar a correção.';
        continue;
      }

      String campo = chaveCampo(entrada.campo);
      if (campo == null) {
        r.mensagem = 'Não reconheci qual dado deve ser corrigido.';
        continue;
      }

      String valor = texto(entrada.valor);
      if (valor == null) {
        r.mensagem = 'O novo valor não foi informado.';
        continue;
      }

      SObject alvo = registro.getSObjectType().newSObject(registro);
      String erro = aplicar(alvo, campo, valor);
      if (erro != null) {
        r.mensagem = erro;
        continue;
      }

      registros.add(alvo);
      indices.add(i);
    }

    if (registros.isEmpty()) {
      return saida;
    }

    Database.SaveResult[] resultados = Database.update(registros, false);
    for (Integer i = 0; i < resultados.size(); i++) {
      Resultado r = saida[indices[i]];
      r.sucesso = resultados[i].isSuccess();
      if (r.sucesso) {
        r.mensagem = 'Dado atualizado.';
      } else {
        r.mensagem = resultados[i].getErrors().isEmpty()
          ? 'Não consegui gravar a correção.'
          : resultados[i].getErrors()[0].getMessage();
      }
    }
    return saida;
  }

  /** Grava o valor no campo, ou devolve o que dizer quando ele não serve. */
  private static String aplicar(SObject alvo, String campo, String valor) {
    if (campo == 'Nome') {
      if (valor.length() < 2) {
        return 'Digite seu nome completo para eu corrigir.';
      }
      alvo.put('FirstName', null);
      alvo.put('LastName', valor.left(80));
      return null;
    }

    if (campo == 'Email') {
      if (!Pattern.matches('^[^@\\s]+@[^@\\s.]+\\.[^@\\s]+$', valor)) {
        return 'Esse e-mail não parece válido. Digite novamente, por favor.';
      }
      alvo.put('Email', valor.left(80));
      return null;
    }

    if (campo == 'Telefone') {
      String digitos = STE_Telefone.digitos(valor);
      if (digitos == null || digitos.length() < MINIMO_DIGITOS_TELEFONE) {
        return 'Digite o telefone com DDD, por favor.';
      }
      alvo.put('MobilePhone', valor.left(40));
      return null;
    }

    if (campo == 'Genero') {
      String genero = genero(valor);
      if (genero == null) {
        return 'Escolha uma das opções nos botões abaixo.';
      }
      alvo.put('STE_Genero__c', genero);
      return null;
    }

    return 'Não reconheci qual dado deve ser corrigido.';
  }

  /** Aceita o rótulo que o assistente mostra e também a chave técnica. */
  private static String chaveCampo(String valor) {
    String limpo = texto(valor);
    if (limpo == null)
      return null;
    String c = limpo.toLowerCase();
    if (c.startsWith('nome'))
      return 'Nome';
    if (c.startsWith('e-mail') || c.startsWith('email'))
      return 'Email';
    if (c.startsWith('telefone') || c.startsWith('whatsapp'))
      return 'Telefone';
    if (c.startsWith('gênero') || c.startsWith('genero'))
      return 'Genero';
    return null;
  }

  private static String genero(String valor) {
    String limpo = texto(valor);
    if (limpo == null)
      return null;
    for (String opcao : GENEROS) {
      if (opcao.equalsIgnoreCase(limpo))
        return opcao;
    }
    return null;
  }

  /** Id de Lead ou de Contato; qualquer outra coisa não serve. */
  private static Id idValido(String valor) {
    String limpo = texto(valor);
    if (limpo == null)
      return null;
    try {
      Id candidato = (Id) limpo;
      Schema.SObjectType tipo = candidato.getSObjectType();
      return (tipo == Lead.SObjectType || tipo == Contact.SObjectType)
        ? candidato
        : null;
    } catch (Exception e) {
      return null;
    }
  }

  private static String texto(String valor) {
    return String.isBlank(valor) ? null : valor.trim();
  }
}