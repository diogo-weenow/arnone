/**
 * Registra o candidato no caminho em que um arquivo de CNH foi recebido.
 *
 * O valor da resposta de CNH e definido no servidor para que o fluxo nao
 * dependa do passo Set Variable do bot apos um CollectAttachment.
 */
public without sharing class STE_BotRegistrarCandidatoQuente {
  public class Entrada {
    @InvocableVariable(label='E-mail' required=true)
    public String email;

    @InvocableVariable(label='Nome completo' required=true)
    public String nomeCompleto;

    @InvocableVariable(label='Resposta pre-inscricao')
    public String respostaPreInscricao;

    @InvocableVariable(label='Resposta faixa etaria')
    public String respostaIdade;

    @InvocableVariable(label='Ja trabalhou com Telecom')
    public String jaTrabalhouTelecom;

    @InvocableVariable(label='Qual empresa de Telecom')
    public String empresaTelecomAnterior;

    /**
     * O dialogo Processar CNH recebida envia este parametro. Sem declara-lo
     * aqui a plataforma recusa a invocacao inteira por parametro desconhecido,
     * e o metodo nem chega a executar.
     *
     * Fica declarado e nao usado de proposito: quem vincula o arquivo ao Lead
     * e o flow STE_Vincular_Arquivo_CNH, em scheduled path, para rodar como
     * Automated Process e nao depender de permissao de Content do usuario do
     * bot.
     */
    @InvocableVariable(label='Arquivos de CNH recebidos')
    public List<Id> arquivosCNH;

    @InvocableVariable(label='Id roteavel da sessao')
    public String routableId;

    @InvocableVariable(label='Id do usuario final de mensageria')
    public String endUserId;
  }

  public class Resultado {
    @InvocableVariable(label='Sucesso')
    public Boolean sucesso;

    @InvocableVariable(label='Mensagem')
    public String mensagem;

    @InvocableVariable(label='Id do registro')
    public String recordId;

    @InvocableVariable(label='Tipo do registro')
    public String tipoRegistro;

    @InvocableVariable(label='Atende aos critérios da turma')
    public Boolean elegivel;
  }

  @InvocableMethod(
    label='Registrar candidato com CNH recebida - Stech Telecom'
    description='Registra o candidato como envio imediato e classificacao Quente apos o recebimento de um arquivo.'
    category='Stech Telecom'
  )
  public static List<Resultado> registrar(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return new List<Resultado>();
    }

    List<STE_BotRegistrarCandidato.Entrada> baseEntradas = new List<STE_BotRegistrarCandidato.Entrada>();
    for (Entrada entrada : entradas) {
      STE_BotRegistrarCandidato.Entrada base = new STE_BotRegistrarCandidato.Entrada();
      if (entrada != null) {
        base.email = entrada.email;
        base.nomeCompleto = entrada.nomeCompleto;
        base.respostaPreInscricao = entrada.respostaPreInscricao;
        base.respostaIdade = entrada.respostaIdade;
        base.jaTrabalhouTelecom = entrada.jaTrabalhouTelecom;
        base.empresaTelecomAnterior = entrada.empresaTelecomAnterior;
        base.routableId = entrada.routableId;
        base.endUserId = entrada.endUserId;
      }
      base.respostaCNH = 'Vou enviar agora';
      baseEntradas.add(base);
    }

    List<STE_BotRegistrarCandidato.Resultado> baseResultados = STE_BotRegistrarCandidato.registrar(
      baseEntradas
    );
    List<Resultado> resultados = new List<Resultado>();
    for (STE_BotRegistrarCandidato.Resultado base : baseResultados) {
      Resultado resultado = new Resultado();
      resultado.sucesso = base.sucesso;
      resultado.mensagem = base.mensagem;
      resultado.recordId = base.recordId;
      resultado.tipoRegistro = base.tipoRegistro;
      resultado.elegivel = base.elegivel;
      resultados.add(resultado);
    }
    return resultados;
  }
}