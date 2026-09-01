/**
 * CLICKUP-9350 — o que a tela de conversão precisa saber antes de perguntar
 * qualquer coisa ao usuário: se o lead passa nos portões do card, e se já
 * existe Conta com o mesmo CNPJ.
 *
 * Está separada de SOL_ConverterLead por limite da plataforma: uma classe Apex
 * só aceita um método @InvocableMethod. Os portões continuam morando lá e são
 * chamados daqui, para não existirem duas versões da mesma regra.
 *
 * Esta classe não grava nada. Ela é chamada toda vez que o botão é aberto,
 * inclusive quando o usuário vai desistir.
 */
public with sharing class SOL_PrepararConversao {
  /** O que a tela precisa saber antes de perguntar qualquer coisa ao usuário. */
  public class Preparo {
    @InvocableVariable(label='Pode converter')
    public Boolean podeConverter;

    @InvocableVariable(label='Impedimento')
    public String impedimento;

    @InvocableVariable(label='Exige liberação do ART 360')
    public Boolean exigeLiberacaoArt;

    @InvocableVariable(label='Resumo do lead')
    public String resumo;

    @InvocableVariable(label='Id da conta sugerida')
    public String contaSugeridaId;

    @InvocableVariable(label='Conta sugerida')
    public String contaSugerida;

    @InvocableVariable(label='Id do contato sugerido')
    public String contatoSugeridoId;

    @InvocableVariable(label='Contato sugerido')
    public String contatoSugerido;

    private Preparo() {
      this.podeConverter = false;
      this.exigeLiberacaoArt = false;
    }
  }

  @InvocableMethod(
    label='Preparar conversão — Arnone Soluções'
    description='Confere os pré-requisitos do lead e procura Conta existente pelo CNPJ normalizado, sem alterar nada.'
    category='Arnone Soluções'
  )
  public static List<Preparo> preparar(List<Id> leadIds) {
    List<Preparo> saida = new List<Preparo>();
    if (leadIds == null || leadIds.isEmpty()) {
      return saida;
    }

    Map<Id, Lead> leads;
    try {
      leads = new Map<Id, Lead>(
        (List<Lead>) Database.query(
          'SELECT ' +
            SOL_ConverterLead.CAMPOS_LEAD +
            ' FROM Lead WHERE Id IN :leadIds'
        )
      );
    } catch (QueryException e) {
      // Sem FLS nos campos da unidade a consulta nem roda: para quem não tem
      // permissão o campo simplesmente não existe. A tela precisa dizer isso.
      for (Id ignorado : leadIds) {
        Preparo p = new Preparo();
        p.impedimento = SOL_ConverterLead.SEM_PERMISSAO;
        saida.add(p);
      }
      return saida;
    }
    Map<Id, Integer> arquivos = SOL_ConverterLead.arquivosPorLead(
      leads.keySet()
    );

    for (Id leadId : leadIds) {
      Preparo p = new Preparo();
      Lead l = leads.get(leadId);
      if (l == null) {
        p.impedimento = 'Lead não encontrado.';
        saida.add(p);
        continue;
      }

      Integer quantos = arquivos.containsKey(leadId) ? arquivos.get(leadId) : 0;
      p.impedimento = SOL_ConverterLead.impedimentoPara(l, quantos);
      if (p.impedimento != null) {
        saida.add(p);
        continue;
      }

      // Nenhum produto dispensa mais a procuração, então a tela não tem o que
      // pedir a mais: o portão único já barrou quem não tem o documento.
      // O campo continua existindo na resposta para não quebrar o flow, que o
      // referencia — e agora responde sempre "não".
      p.exigeLiberacaoArt = false;
      p.podeConverter = true;
      p.resumo = SOL_ConverterLead.resumoDe(l, quantos);

      Account conta = SOL_ConverterLead.contaPorCnpj(l.CNPJ__c);
      if (conta != null) {
        p.contaSugeridaId = conta.Id;
        p.contaSugerida =
          conta.Name +
          (String.isBlank(conta.Unidades_Atendidas__c)
            ? ''
            : ' — atendida por ' + conta.Unidades_Atendidas__c);

        Contact c = SOL_ConverterLead.contatoDaConta(conta.Id, l);
        if (c != null) {
          p.contatoSugeridoId = c.Id;
          p.contatoSugerido =
            c.Name + (String.isBlank(c.Email) ? '' : ' — ' + c.Email);
        }
      }
      saida.add(p);
    }
    return saida;
  }
}